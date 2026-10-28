#!/usr/bin/perl
#
# Module: vyatta-tshark.pl
#
# **** License ****
#
# Copyright (c) 2019-2020, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014-2015 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2011-2013 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Author: John Southworth
# Date: Sept. 2011
# Description: run tshark on a given interface with options
#
# **** End License ****
#

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper qw(Dumper);
use JSON         qw(decode_json);

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Dataplane;

my $TSHARK = "/usr/bin/tshark";
my $DEBUG  = 0;

sub check_if_interface_is_tsharkable {
    my ($interface) = @_;

    open( my $tshark, '-|', $TSHARK, '-D' )
      or die "tshark failed: $!\n";
    my @lines = <$tshark>;
    close $tshark;
    return 1 if grep { m{^\d+[.][ ]\Q$interface\E$}x } @lines;
    die "Unable to capture traffic on $interface\n";
}

my ( $detail, $filter, $intf, $unlimited, $save, $files, $size, $swonly, $snaplen, $bandwidth );
my $count = 1000;

#
# The size parameter can have one of the following
# unit suffixes:
#
# - [kK] KiB (1024 bytes)
# - [mM] MiB (1048576 bytes)
# - [gG] GiB (1073741824 bytes)
# - [tT] TiB (109951162778 bytes)
#
# Note: tshark's default size unit is KiB
sub parse_size {
    my ( $name, $parm ) = @_;
    my %mult = ( 'T' => 1073741824, 'G' => 1048576, 'M' => 1024, 'K' => 1 );

    die "Invalid parameter: $name\n" if ( $name ne "size" );
    my ( $value, $unit ) = $parm =~ m/^([0-9]+)([kKmMgGtT])?$/x;
    die "Invalid size. (e.g. 1 or 1K = 1KiB, 1M = 1MiB, 1G = 1Gib, 1T = 1TiB)\n"
      unless ($value);
    $size = $value * $mult{ uc( $unit // "K" ) };
    return;
}

#
# When invoked to monitor a dataplane interface, the script is passed
# a "stream" of tokens corresponding to the YANG nodes. That is,
# "detail capture-size 100" rather than "--detail --capture-size 100".
#
# Process the tokens and turn them into options suitable for use by
# the main GetOptions parser.
#
sub generate_options {
    my (@argv) = @_;

    my %flagopt = (
        'detail'        => 1,
        'unlimited'     => 1,
        'software-only' => 1,
    );

    my @newargv;
    my $next_is_param = 0;
    foreach my $arg (@argv) {
        if ($next_is_param) {
            $next_is_param = 0;
            push @newargv, $arg;
            next;
        }
        ( my $name = $arg ) =~ s/^--//x;
        $next_is_param = 1 if !$flagopt{$name};
        push @newargv, "--$name";
    }
    return @newargv;
}

# The dataplane's capture session on $intf, or undef.
sub capture_show {
    my ($capture_intf) = @_;

    my ( $dpids, $dpconns ) = Vyatta::Dataplane::setup_fabric_conns();
    my @dprsp = eval { vplane_exec_cmd( "capture show $capture_intf", $dpids, $dpconns, 1 ) };
    foreach my $rsp (@dprsp) {
        my $json = @{$rsp}[0];
        next if !defined $json;
        my $session = eval { decode_json($json) };
        return $session if $session;
    }
    return;
}

# Options the running session fixes: those that differ are dropped and
# reported.
sub drop_conflicting_options {
    my ($capture) = @_;
    my @ignore_options;

    if ( defined($snaplen) && ( $snaplen != $capture->{'snaplen'} ) ) {
        push @ignore_options, "capture-size";
        $snaplen = undef;
    }
    if ( defined($swonly) && ( $swonly != $capture->{'software-only'} ) ) {
        push @ignore_options, "software-only";
        $swonly = undef;
    }
    if ( defined($bandwidth) && ( $bandwidth != $capture->{'bandwidth'} ) ) {
        push @ignore_options, "bandwidth";
        $bandwidth = undef;
    }
    print "Interface already being monitored, ignoring options: "
      . join( ",", @ignore_options ) . "\n"
      if @ignore_options;
    return;
}

#
# main
#

local @ARGV = generate_options(@ARGV);

my $result = GetOptions(
    "detail!"        => \$detail,
    "filter=s"       => \$filter,
    "save=s"         => \$save,
    "intf=s"         => \$intf,
    "count=s"        => \$count,
    "unlimited!"     => \$unlimited,
    "files=i"        => \$files,
    "size=s"         => \&parse_size,
    "software-only"  => \$swonly,
    "capture-size=i" => \$snaplen,
    "bandwidth=i"    => \$bandwidth,
);

if ( !$result ) {
    print "Invalid option specifications\n";
    exit 1;
}

die "No interface specified!\n"
  unless defined($intf);

check_if_interface_is_tsharkable($intf);

my $existing_session = capture_show($intf);

if ($DEBUG) {
    print "TSHARK existing capture session:\n" . Dumper($existing_session);
    print "TSHARK options:\n" . Dumper(@ARGV);
}

my @args = ( 'tshark', '-n', '-i', $intf );

if ( defined($save) ) {
    die "Please name your file <filename>.pcap\n"
      unless $save =~ m{[.]pcap}x;

    push @args, '-w', $save;
    push @args, '-a', "filesize:$size"
      if defined($size);

    push @args, '-b', "files:$files"
      if defined($files);
}
else {
    push @args, '-c', $count
      unless $unlimited;
}

drop_conflicting_options( $existing_session->{'capture'} )
  if $existing_session && $existing_session->{'capture'}->{'active'};

push @args, '-s', $snaplen if defined($snaplen);
push @args, '-V' if $detail;
push @args, '-f', $filter if defined($filter);

#
# The following are dataplane/platform specific parameters with no
# corresponding tshark facility. Use environment variables to pass the
# values through to the libpcap dataplane plugin module (and from
# there to the dataplane itself).
#
local $ENV{'VYATTA_MONITOR_SWONLY'}    = $swonly    if defined($swonly);
local $ENV{'VYATTA_MONITOR_BANDWIDTH'} = $bandwidth if defined($bandwidth);

exec {$TSHARK} @args
  or die "Can't exec $TSHARK\n";
