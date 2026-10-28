#! /usr/bin/perl
# Wrapper around the base Linux traceroute command to provide
#  nicer API (ie no flag arguments)
#
# **** License ****
# Copyright (c) 2017,2019, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2014-2016 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2014 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
# **** End License ****
#
# Syntax
#   traceroute [ipv4] [ipv6] [version] HOST
#           [ as-path ]
#           [ bypass-routing ]
#           [ debug-socket ]
#           [ first-ttl VALUE ]
#           [ gateway VALUE ]
#           [ icmp-echo ]
#           [ icmp-extensions ]
#           [ interface VALUE ]
#           [ interval VALUE ]
#           [ max-ttl VALUE ]
#           [ no-fragment ]
#           [ num-queries VALUE ]
#           [ port VALUE ]
#           [ seq-queries VALUE ]
#           [ source-addr VALUE ]
#           [ tcp-syn VALUE ]
#           [ tos VALUE ]
#           [ version ]
#           [ wait-time VALUE ]

use strict;
use warnings;
use NetAddr::IP;
use Data::Validate::IP qw(is_linklocal_ipv6);

# Table for translating options to arguments
my %options = (
    'icmp-echo'       => 'I',
    'tcp-syn'         => 'T',
    'debug-socket'    => 'd',
    'no-fragment'     => 'F',
    'first-ttl'       => 'f:',
    'gateway'         => 'g:',
    'interface'       => 'i:',
    'max-ttl'         => 'm:',
    'seq-queries'     => 'N:',
    'no-map'          => 'n',
    'port'            => 'p:',
    'tos'             => 't:',
    'wait-time'       => 'w:',
    'num-queries'     => 'q:',
    'bypass-routing'  => 'r',
    'source-addr'     => 's:',
    'interval'        => 'z:',
    'icmp-extensions' => 'e',
    'as-path'         => 'A',
    'version'         => 'V',
);

# Splits "routing-instance NAME" out of the arguments.
sub split_rti {
    my (@argv) = @_;
    my ( $rti, @rest );
    while (@argv) {
        my $word = shift @argv;
        if ( $word eq "routing-instance" ) {
            $rti = shift @argv;
            next;
        }
        push @rest, $word;
    }
    return ( $rti, @rest );
}

# Asks for the outgoing interface a link-local destination needs.
sub ask_interface {
    print "\nSpecify outgoing interface: ";
    ## no critic (InputOutput::ProhibitExplicitStdin) reason: an interactive prompt; <> would open the arguments as files
    my $out_iface = <STDIN>;
    ## use critic
    chomp($out_iface);
    die "traceroute: Outgoing interface not specified.\n"
      if ( $out_iface eq "" );
    return $out_iface;
}

# The traceroute arguments for the words after the host.
sub option_args {
    my (@words) = @_;
    my ( @cmdargs, $int_spcfd );
    while ( my $arg = shift @words ) {
        my $traceroutearg = $options{$arg};
        die "traceroute: unknown option $arg\n"
          unless $traceroutearg;

        push @cmdargs, "-" . substr( $traceroutearg, 0, 1 );
        next if rindex( $traceroutearg, ':' ) == -1;

        my $optarg = shift @words;
        die "traceroute: missing argument for $arg option\n"
          unless defined($optarg);
        $int_spcfd = 1 if "i:" eq $traceroutearg;
        push @cmdargs, $optarg;
    }
    return ( $int_spcfd, @cmdargs );
}

my ( $rti, @args ) = split_rti(@ARGV);

exec "/usr/sbin/chvrf", $rti, "/opt/vyatta/bin/traceroute.pl", @args
  if ( defined $rti );

my $cmd = '/usr/bin/traceroute';
my @cmdargs;
my $host;

# First argument is host or ip version
while (@args) {
    my $first_arg = shift @args;
    if ( $first_arg eq 'ipv6' ) {
        push @cmdargs, '-6';
    }
    elsif ( $first_arg ne 'ipv4' ) {
        $host = $first_arg;
        last;
    }
}

die "traceroute: Missing host\n"
  unless defined($host);
my $ip = NetAddr::IP->new($host);
die "traceroute: Unknown host: $host\n"
  unless defined($ip);

my $ip6_ll = 0;
if ( !@cmdargs && $ip->version ) {
    if ( $ip->version == 6 ) {
        push @cmdargs, '-6';
        $ip6_ll = is_linklocal_ipv6($host);
    }
    elsif ( $ip->version != 4 ) {
        die "Unknown address: $host\n";
    }
}

my ( $int_spcfd, @optargs ) = option_args(@args);
push @cmdargs, @optargs;

if ( $ip6_ll && !$int_spcfd ) {
    push @cmdargs, "-i", ask_interface();
}

exec $cmd, @cmdargs, $host;
