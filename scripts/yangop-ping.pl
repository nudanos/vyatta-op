#!/usr/bin/perl
#
# Copyright (c) 2017,2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014-2016 Brocade Communications Systems, Inc.
# All rights reserved
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use IPC::Cmd qw[run];
use JSON;

my $input = do { local $/ = undef; <> };
my $rpc   = decode_json $input;

# The RPC's values are arguments to ping, never shell words.
my @cmd = ( "/opt/vyatta/bin/ping", $rpc->{host} );
foreach my $key ( sort keys %{$rpc} ) {
    push @cmd, $key, $rpc->{$key} unless $key =~ m{^(?:-|host)}x;
}
push @cmd, "quiet";    # Always run in quiet mode

my %out;
my ( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) =
  run( command => \@cmd, verbose => 0 );
my @result = split( /\n/x, join( "", @{$stdout_buf} ) );
my $rtt    = qr{^rtt[ ]min/avg/max/mdev[ ]=[ ]}x;
foreach my $line (@result) {
    if ( $line =~ m{^(\d+)\s+packets\s+transmitted,\s+(\d+)\s+received}x ) {
        $out{"tx-packet-count"} = int($1);
        $out{"rx-packet-count"} = int($2);
    }
    elsif ( $line =~ m{$rtt([0-9.]+)/([0-9.]+)/([0-9.]+)/}x ) {

        # Units are milliseconds.  We don't display sub-ms times as that
        # either requires changing the YANG units, or the type, and neither
        # is really allowed.  'ping' is a basic diagnostic - if times are
        # that small, everything is working pretty well ...
        $out{"min-delay"}     = int($1);
        $out{"average-delay"} = int($2);
        $out{"max-delay"}     = int($3);
    }
}

if ( !@result ) {
    $out{"tx-packet-count"} = $rpc->{count};
    $out{"rx-packet-count"} = 0;
}

print encode_json( \%out );
