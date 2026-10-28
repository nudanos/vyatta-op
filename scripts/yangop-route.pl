#!/usr/bin/perl
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2015 Brocade Communications Systems, Inc.
# All rights reserved
#
# SPDX-License-Identifier: GPL-2.0-only
use strict;
use warnings;
use JSON;

my $input = do { local $/ = undef; <> };
my $rpc   = decode_json $input;

my @cmd = ("/opt/vyatta/bin/yangop-get-route");

my $family = $rpc->{family} || "ipv4";
push @cmd, "-6" if $family eq "ipv6";

my $dest = $rpc->{destination};
push @cmd, "-r", $dest if $dest;

exec { $cmd[0] } @cmd or die "Cannot run $cmd[0]: $!\n";
