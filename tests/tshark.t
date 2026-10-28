#!/usr/bin/perl
# Tests for scripts/vyatta-tshark.pl, run from a copy whose tshark is a
# stub (it lists dp0s3 for -D and otherwise prints its arguments and the
# dataplane environment), with a stub Vyatta::Dataplane.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 11;

my $tmp = tempdir( CLEANUP => 1 );

sub write_file {
    my ( $file, $content, $mode ) = @_;
    open my $fh, '>', $file or BAIL_OUT("cannot write $file: $!");
    print {$fh} $content;
    close $fh or BAIL_OUT("cannot close $file: $!");
    chmod $mode, $file if defined $mode;
    return;
}

open my $in, '<', "$FindBin::Bin/../scripts/vyatta-tshark.pl"
  or BAIL_OUT("vyatta-tshark.pl: $!");
my $script = do { local $/ = undef; <$in> };
close $in                                       or BAIL_OUT("vyatta-tshark.pl: $!");
$script =~ s{"/usr/bin/tshark"}{"$tmp/tshark"}x or BAIL_OUT('no tshark path');
write_file( "$tmp/vyatta-tshark.pl", $script );
write_file( "$tmp/tshark", <<'END', oct 755 );
#!/bin/sh
if [ "$1" = -D ]; then echo "1. dp0s3"; echo "2. any"; exit 0; fi
echo "tshark $*${VYATTA_MONITOR_SWONLY:+ swonly=$VYATTA_MONITOR_SWONLY}${VYATTA_MONITOR_BANDWIDTH:+ bw=$VYATTA_MONITOR_BANDWIDTH}"
END

sub tshark {
    my ( $capture, @args ) = @_;
    local $ENV{STUB_CAPTURE} = $capture;
    my $pid = open my $out, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 126;
        exec $^X, "-I$FindBin::Bin/lib", "$tmp/vyatta-tshark.pl", @args or exit 127;
    }
    my $text = do { local $/ = undef; <$out> }
      // q{};
    close $out;
    return $text;
}

is( tshark( undef, qw(--intf dp0s3) ), "tshark -n -i dp0s3 -c 1000\n", 'default: 1000 packets' );
is(
    tshark( undef, qw(--intf dp0s3 --unlimited --detail --filter tcp) ),
    "tshark -n -i dp0s3 -V -f tcp\n",
    'options: unlimited, detail, filter'
);
is(
    tshark( undef, qw(--intf dp0s3 detail capture-size 100) ),
    "tshark -n -i dp0s3 -c 1000 -s 100 -V\n",
    'YANG token form: detail and capture size'
);
is(
    tshark( undef, qw(--intf dp0s3 --save x.pcap --size 1M --files 3) ),
    "tshark -n -i dp0s3 -w x.pcap -a filesize:1024 -b files:3\n",
    'save: file size in KiB and ring of files'
);
like(
    tshark( undef, qw(--intf dp0s3 --save x.txt) ),
    qr{name[ ]your[ ]file}x,
    'save: only to a .pcap file'
);
like( tshark( undef, qw(--intf dp0s3 --size 1X) ), qr{Invalid[ ]size}x, 'size: bad unit refused' );
like(
    tshark( undef, qw(--intf dp0s9) ),
    qr{Unable[ ]to[ ]capture[ ]traffic[ ]on[ ]dp0s9}x,
    'unknown interface refused'
);
like( tshark(undef), qr{No[ ]interface[ ]specified}x, 'no interface refused' );
is(
    tshark( undef, qw(--intf dp0s3 --unlimited --software-only --bandwidth 10) ),
    "tshark -n -i dp0s3 swonly=1 bw=10\n",
    'dataplane options passed in the environment'
);

my $active = '{"capture":{"active":true,"snaplen":64,"software-only":0,"bandwidth":0}}';
is(
    tshark( $active, qw(--intf dp0s3 --unlimited --capture-size 100) ),
    "Interface already being monitored, ignoring options: capture-size\n" . "tshark -n -i dp0s3\n",
    'existing session: conflicting options ignored'
);
is(
    tshark( $active, qw(--intf dp0s3 --unlimited --capture-size 64) ),
    "tshark -n -i dp0s3 -s 64\n",
    'existing session: matching options kept'
);
