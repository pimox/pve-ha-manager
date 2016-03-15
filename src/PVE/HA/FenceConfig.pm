package PVE::HA::FenceConfig;

use strict;
use warnings;
use PVE::Tools;
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file);
use Data::Dumper;

my $__die = sub {
    my ($fn, $lineno, $error_message) = @_;

    die "error in '$fn' at $lineno: $error_message\n";
};

sub parse_config {
    my ($fn, $raw) = @_;

    $raw = '' if !$raw;

    my $config = {};

    my $lineno = 0;
    my $priority = 0;

    while ($raw =~ /^\h*(.*?)\h*$/gm) {
	my $line = $1;
	$lineno++;

	next if !$line || $line =~ /^#/;

	if ($line =~ m/^(device|connect)\s+(\S+)\s+(\S+)\s+(.+)$/) {
	    my ($command, $dev_name, $target) = ($1, $2, $3);

	    # allow spaces, and other special chars inside of quoted strings
	    # with escape support
	    my @arg_array = $4 =~ /(\w+(?:=(?:(?:\"(?:[^"\\]|\\.)*\")|\S+))?)/g;

	    my $dev_number = 1; # default

	    # check for parallel devices
	    if ($dev_name =~ m/^(\w+)(:(\d+))?/) {
		$dev_name = $1;
		$dev_number = $3 if $3;
	    }

	    if ($command eq "device") {

		my $dev = $config->{$dev_name} || {};

		&$__die($fn, $lineno, "device '$dev_name:$dev_number' already declared")
		    if ($dev && $dev->{sub_devs}->{$dev_number});

		$dev->{sub_devs}->{$dev_number} = {
		    agent => $target,
		    args => [ @arg_array ]
		};
		$dev->{priority} = $priority++ if !$dev->{priority};

		$config->{$dev_name} = $dev;

	    } else { # connect nodes to devices

		&$__die($fn, $lineno, "device '$dev_name' must be declared before" .
			       " you can connect to it") if !$config->{$dev_name};

		&$__die($fn, $lineno, "No parallel device '$dev_name:$dev_number' found")
		    if !$config->{$dev_name}->{sub_devs}->{$dev_number};

		my $sdev = $config->{$dev_name}->{sub_devs}->{$dev_number};

		my ($node) = $target =~ /node=(\w+)/;
		&$__die($fn, $lineno, "node=nodename needed to connect device ".
			  "'$dev_name' to node") if !$node;

		&$__die($fn, $lineno, "node '$node' already connected to device ".
			  "'$dev_name:$dev_number'") if $sdev->{node_args}->{$node};

		$sdev->{node_args}->{$node} = [ @arg_array ];

		$config->{$dev_name}->{sub_devs}->{$dev_number} = $sdev;

	    }

	} else {
	    warn "$fn ignore line $lineno: $line\n"
	}
    }

    return $config;

}

sub write_config {
    my ($fn, $data) = @_;

    my $raw = '';

    foreach my $dev_name (sort {$a->{priority} <=> $b->{priority}} keys %$data) {
	my $d = $data->{$dev_name};

	foreach my $sub_dev_nr (sort keys %{$d->{sub_devs}}) {
	    my $sub_dev = $d->{sub_devs}->{$sub_dev_nr};
	    my $dev_arg_str = join (' ', @{$sub_dev->{args}});

	    $raw .= "\ndevice $dev_name:$sub_dev_nr $sub_dev->{agent} $dev_arg_str\n";

	    foreach my $node (sort keys %{$sub_dev->{node_args}}) {
		my $node_arg_str = join (' ', @{$sub_dev->{node_args}->{$node}});

		$raw .= "connect $dev_name:$sub_dev_nr $node_arg_str\n";
	    }
	}
    }

    return $raw;
}



sub gen_arg_str {
    my (@arguments) = @_;

    my @shell_args = ();
    foreach my $arg (@arguments) {
	# we need to differ long and short opts!
	my $prefix = (length($arg) == 1) ? '-' : '--';
	push @shell_args, "$prefix$arg";
    }

    return join (' ', @shell_args);
}


# returns command list to execute,
# can be more than one command if parallel devices are configured
# 'try' denotes the number of devices we should skip and normaly equals to
# failed fencing tries
sub get_commands {
    my ($node, $try, $config) = @_;

    return undef if !$node || !$config;

    $try = 0 if !$try || $try<0;

    foreach my $device (sort {$a->{priority} <=> $b->{priority}} values %$config) {
	my @commands;

	#foreach my $sub_dev (values %{$device->{sub_devs}}) {
	foreach my $sub_dev_nr (sort keys %{$device->{sub_devs}}) {
	    my $sub_dev = $device->{sub_devs}->{$sub_dev_nr};

	    if (my $node_args = $sub_dev->{node_args}->{$node}) {
		push @commands, { agent=>$sub_dev->{agent},
				  sub_dev => $sub_dev_nr,
				  param => [@{$sub_dev->{args}}, @{$node_args}]};
	    }

	}

	if (@commands>0) {
	    $try--;
	    return [ @commands ] if $try<0;
	}
    }

    # out of tries or no device for this node
    return undef;
}


sub count_devices {
    my ($node, $config) = @_;

    my $count = 0;

    return 0 if !$config;

    foreach my $device (values %$config) {
	foreach my $sub_dev (values %{$device->{sub_devs}}) {
	    if ($sub_dev->{node_args}->{$node}) {
		$count++;
		last; # no need to count parallel devices
	    }
	}
    }

    return $count;
}

1;
