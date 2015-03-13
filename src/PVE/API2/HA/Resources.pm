package PVE::API2::HA::Resources;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::HA::Config;
use PVE::HA::Resources;
use PVE::HA::Env::PVE2;
use HTTP::Status qw(:constants);
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use Data::Dumper;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

# fixme: use cfs_read_file

my $ha_resources_config = "/etc/pve/ha/resources.cfg";

my $resource_type_enum = PVE::HA::Resources->lookup_types();

# fixme: fix permissions

my $api_copy_config = sub {
    my ($cfg, $sid) = @_;

    die "no such resource '$sid'\n" if !$cfg->{ids}->{$sid};

    my $scfg = dclone($cfg->{ids}->{$sid});
    $scfg->{sid} = $sid;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "List HA resources.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => {
		description => "Only list resources of specific type",
		type => 'string',
		enum => $resource_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { sid => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{sid}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::HA::Env::PVE2::read_resources_config();

	my $res = [];
	foreach my $sid (keys %{$cfg->{ids}}) {
	    my $scfg = &$api_copy_config($cfg, $sid);
	    next if $param->{type} && $param->{type} ne $scfg->{type};
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{sid}',
    method => 'GET',
    description => "Read resource configuration.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    sid => get_standard_option('pve-ha-resource-id'),
	},
    },
    returns => {},
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::HA::Env::PVE2::read_resources_config();

	return &$api_copy_config($cfg, $param->{sid});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new HA resource.",
    parameters => PVE::HA::Resources->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $sid = extract_param($param, 'sid');
	my ($type, $name) = PVE::HA::Tools::parse_sid($sid);

	if (my $param_type = extract_param($param, 'type')) {
	    # useless, but do it anyway
	    die "types does not match\n" if $param_type ne $type;
	}

	my $plugin = PVE::HA::Resources->lookup($type);
	$plugin->verify_name($name);

	my $opts = $plugin->check_config($sid, $param, 1, 1);

	PVE::HA::Env::PVE2::lock_ha_config(
	    sub {

		my $cfg = PVE::HA::Env::PVE2::read_resources_config();

		if ($cfg->{ids}->{$sid}) {
		    die "resource ID '$sid' already defined\n";
		}

		$cfg->{ids}->{$sid} = $opts;

		PVE::HA::Env::PVE2::write_resources_config($cfg)

	    }, "create resource failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{sid}',
    method => 'PUT',
    description => "Update resource configuration.",
    parameters => PVE::HA::Resources->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $digest = extract_param($param, 'digest');
	my $delete = extract_param($param, 'delete');

	my $sid = extract_param($param, 'sid');
	my ($type, $name) = PVE::HA::Tools::parse_sid($sid);

	if (my $param_type = extract_param($param, 'type')) {
	    # useless, but do it anyway
	    die "types does not match\n" if $param_type ne $type;
	}

	PVE::HA::Env::PVE2::lock_ha_config(
	    sub {

		my $cfg = PVE::HA::Env::PVE2::read_resources_config();

		PVE::SectionConfig::assert_if_modified($cfg, $digest);

		my $scfg = $cfg->{ids}->{$sid} ||
		    die "no such resource '$sid'\n";

		my $plugin = PVE::HA::Resources->lookup($scfg->{type});
		my $opts = $plugin->check_config($sid, $param, 0, 1);

		foreach my $k (%$opts) {
		    $scfg->{$k} = $opts->{$k};
		}

		if ($delete) {
		    my $options = $plugin->private()->{options}->{$type};
		    foreach my $k (PVE::Tools::split_list($delete)) {
			my $d = $options->{$k} ||
			    die "no such option '$k'\n";
			die "unable to delete required option '$k'\n"
			    if !$d->{optional};
			die "unable to delete fixed option '$k'\n"
			    if $d->{fixed};
			delete $scfg->{$k};
		    }
		}

		PVE::HA::Env::PVE2::write_resources_config($cfg)

	    }, "update resource failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{sid}',
    method => 'DELETE',
    description => "Delete resource configuration.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    sid => get_standard_option('pve-ha-resource-id'),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $sid = extract_param($param, 'sid');

 	PVE::HA::Env::PVE2::lock_ha_config(
	    sub {

		my $cfg = PVE::HA::Env::PVE2::read_resources_config();

		delete $cfg->{ids}->{$sid};

		PVE::HA::Env::PVE2::write_resources_config($cfg)

	    }, "delete storage failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'migrate',
    protected => 1,
    path => '{sid}/migrate',
    method => 'POST',
    description => "Request resource migration (online) to another node.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    sid => get_standard_option('pve-ha-resource-id'),
	    node => get_standard_option('pve-node'),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	PVE::HA::Env::PVE2->queue_crm_commands("migrate $param->{sid} $param->{node}");
	    
	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'relocate',
    protected => 1,
    path => '{sid}/relocate',
    method => 'POST',
    description => "Request resource relocatzion to another node. This stops the service on the old node, and restarts it on the target node.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    sid => get_standard_option('pve-ha-resource-id'),
	    node => get_standard_option('pve-node'),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	PVE::HA::Env::PVE2->queue_crm_commands("relocate $param->{sid} $param->{node}");
	    
	return undef;
    }});

1;
