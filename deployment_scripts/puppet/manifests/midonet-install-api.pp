$fuel_settings = parseyaml($astute_settings_yaml)
$all_nodes = $fuel_settings['nodes']
$nsdb_nodes = filter_nodes($all_nodes, 'role', 'nsdb')
$zoo_ips = generate_api_zookeeper_ips($nsdb_nodes)
$m_version = 'v2015.06'
$primary_controller_nodes = filter_nodes($all_nodes, 'role', 'primary-controller')
$controllers = concat($primary_controller_nodes, filter_nodes($all_nodes, 'role', 'controller'))

$mem = $midonet_settings['mem']
$mem_version = $midonet_settings['mem_version']
$mem_user = $midonet_settings['mem_repo_user']
$mem_password = $midonet_settings['mem_repo_password']

# MidoNet API manifest

if $mem {
  $mido_repo = $operatingsystem ? {
    'CentOS' => "http://${mem_user}:${mem_password}@yum.midokura.com/repo/${mem_version}/stable/RHEL",
    'Ubuntu' => "http://${mem_user}:${mem_password}@apt.midokura.com/midonet/${mem_version}/stable"
  }
} else {
  $mido_repo = $operatingsystem ? {
    'CentOS' => "http://repo.midonet.org/midonet/${m_version}/RHEL",
    'Ubuntu' => "http://repo.midonet.org/midonet/${m_version}"
  }
}

class {'::midonet::repository':
  midonet_repo       => $mido_repo,
  manage_distro_repo => false,
  openstack_release  => 'juno'
} ->

class {'::midonet::midonet_api':
  zk_servers           => $zoo_ips,
  keystone_auth        => true,
  keystone_host        => $::fuel_settings['management_vip'],
  keystone_admin_token => $::fuel_settings['keystone']['admin_token'],
  keystone_tenant_name => $::fuel_settings['access']['tenant'],
  bind_address         => $::ipaddress_br_mgmt,
  api_ip               => $::fuel_settings['public_vip'],
  api_port             => '8081',
  require              => Class['::midonet::repository']
}

# HA proxy configuration
Haproxy::Service        { use_include   => true }
Haproxy::Balancermember { use_include => true }

Openstack::Ha::Haproxy_service {
  server_names        => filter_hash($controllers, 'name'),
  ipaddresses         => filter_hash($controllers, 'internal_address'),
  public_virtual_ip   => $::fuel_settings['public_vip'],
  internal_virtual_ip => $::fuel_settings['management_vip'],
}

openstack::ha::haproxy_service { 'midonetapi':
  order                  => 199,
  listen_port            => 8081,
  balancermember_port    => 8081,
  define_backups         => true,
  before_start           => true,
  public                 => true,
  haproxy_config_options => {
    'balance'        => 'roundrobin',
    'option'         => ['httplog'],
  },
  balancermember_options => 'check',
}

exec { 'haproxy reload':
  command   => 'export OCF_ROOT="/usr/lib/ocf"; (ip netns list | grep haproxy) && ip netns exec haproxy /usr/lib/ocf/resource.d/fuel/ns_haproxy reload',
  path      => '/usr/bin:/usr/sbin:/bin:/sbin',
  logoutput => true,
  provider  => 'shell',
  tries     => 10,
  try_sleep => 10,
  returns   => [0, ''],
}

Haproxy::Listen <||> -> Exec['haproxy reload']
Haproxy::Balancermember <||> -> Exec['haproxy reload']


firewall {'502 Midonet api':
  port => '8081',
  proto => 'tcp',
  action => 'accept',
}
