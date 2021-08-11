#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;

use File::Path qw(make_path remove_tree);

my $opt_nodiff;
my $opt_nofail;
my $opt_notestout;

if (!GetOptions(
    "no-diff" => \$opt_nodiff,
    "no-test-output" => \$opt_notestout,
    "c|continue-on-fail" => \$opt_nofail,
)) {
    print "usage: $0 testdir [--no-diff] [-c | --continue-on-fail] [--no-test-output]\n";
    exit -1;
}

my ($run, $failed) = (0, []);


my $STDOLD;

sub do_run_test {
    my $dir = shift;

    $dir =~ s!/+$!!;

    $run++;
    print "run: $dir\n";

    if ($opt_notestout) {
	open($STDOLD, '>&', STDOUT); # if request redirect stdout into nirvana but save old one
	open(STDOUT, '>>', '/dev/null');
    }

    my $res = system('perl', '-I../', '../pve-ha-tester', "$dir"); # actually running the test

    open (STDOUT, '>&', $STDOLD) if $opt_notestout; # restore back again

    return "Test '$dir' failed\n" if $res != 0;

    return if $opt_nodiff;

    my $logfile = "$dir/status/log";
    my $logexpect = "$dir/log.expect";

    if (-f $logexpect) {
	my $cmd = ['diff', '-u', $logexpect, $logfile]; 
	$res = system(@$cmd);
	return "test '$dir' failed\n" if $res != 0;
    } else {
	$res = system('cp', $logfile, $logexpect);
	return "test '$dir' failed\n" if $res != 0;
    }
    print "end: $dir (success)\n";

    return undef;
}

my sub handle_test_result {
    my ($res, $test) = @_;

    return if !defined($res); # undef -> passed

    push $failed->@*, $test;

    die "$res\n" if !$opt_nofail;
    warn "$res\n";
}

sub run_test {
    my $dir = shift;

    my $res = do_run_test($dir);

    handle_test_result($res, $dir);
}

if (my $testdir = shift) {
    run_test($testdir);
} else {
    foreach my $dir (<test-*>) {
	run_test($dir);
    }
}

my $failed_count = scalar($failed->@*);
my $passed = $run - $failed_count;

my $summary_msg = "passed $passed out of $run tests";

if ($failed_count) {
    $summary_msg .= ", failed test(s):\n  " . join("\n  ", $failed->@*);
} else {
    $summary_msg .= " -> OK";
}

print "$summary_msg\n";

exit($failed_count > 0 ? -1 : 0);
