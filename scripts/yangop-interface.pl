#!/usr/bin/perl
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014-2015 Brocade Communications Systems, Inc.
# All rights reserved
#
# SPDX-License-Identifier: GPL-2.0-only

use lib "/opt/vyatta/share/perl5/";

use strict;
use warnings;
use Vyatta::Interface;
use Vyatta::Misc;
use JSON;

sub get_intf {
    my ( $out, @intfs ) = @_;
    my @allintf = Vyatta::Misc::getInterfaces();
    foreach my $intf (@intfs) {
        die "Invalid interface: $intf\n"
          unless ( grep { $_ eq $intf } @allintf );
        my $interface = Vyatta::Interface->new($intf);
        die "Invalid interface: $intf\n" unless $interface;

        my $admin       = $interface->up() ? 'up' : 'down';
        my $oper        = $interface->operstate();
        my $description = $interface->description();
        my @ip_addr     = getIP( $intf, undef, \&Vyatta::Misc::filter_link_local_loopback );
        my $count       = 0;
        foreach my $ip (@ip_addr) {
            $out->{address}[ $count++ ]->{ip} = $ip;
        }
        $out->{"admin-status"} = $admin;
        $out->{"oper-status"}  = $oper;
        $out->{description}    = $description if $description;
    }
    return;
}

my $input = do { local $/ = undef; <> };
my $rpc   = decode_json $input;

my %out;
get_intf( \%out, $rpc->{name} );
print encode_json( \%out );
