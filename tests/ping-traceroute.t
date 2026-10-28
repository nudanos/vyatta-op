#!/usr/bin/perl
# Tests for scripts/ping and scripts/traceroute.pl, which translate the op
# command's words into ping/traceroute options. They run from copies whose
# ping, ping6, traceroute and chvrf are a stub that prints its arguments.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin;
use Test::More tests => 22;

my $tmp = tempdir( CLEANUP => 1 );

sub write_file {
    my ( $file, $content, $mode ) = @_;
    open my $fh, '>', $file or BAIL_OUT("cannot write $file: $!");
    print {$fh} $content;
    close $fh or BAIL_OUT("cannot close $file: $!");
    chmod $mode, $file if defined $mode;
    return;
}

sub copy_script {
    my ( $name, %paths ) = @_;
    open my $in, '<', "$FindBin::Bin/../scripts/$name" or BAIL_OUT("$name: $!");
    my $script = do { local $/ = undef; <$in> };
    close $in or BAIL_OUT("$name: $!");
    while ( my ( $from, $to ) = each %paths ) {
        $script =~ s{\Q$from\E}{$to}gx or BAIL_OUT("$name: no $from");
    }
    write_file( "$tmp/script-$name", $script );
    return "$tmp/script-$name";
}

foreach my $stub (qw(ping ping6 traceroute chvrf)) {
    write_file( "$tmp/$stub", "#!/bin/sh\necho $stub \"\$@\"\n", oct 755 );
}
my $ping = copy_script(
    'ping',
    "'/bin/ping'"       => "'$tmp/ping'",
    "'/bin/ping6'"      => "'$tmp/ping6'",
    '"/usr/sbin/chvrf"' => "\"$tmp/chvrf\"",
);
my $traceroute = copy_script(
    'traceroute.pl',
    "'/usr/bin/traceroute'" => "'$tmp/traceroute'",
    '"/usr/sbin/chvrf"'     => "\"$tmp/chvrf\"",
);

# Runs a script with arguments and $stdin; returns its combined output.
sub run {
    my ( $stdin, @cmd ) = @_;
    write_file( "$tmp/stdin", $stdin );
    my $pid = open my $out, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDIN,  '<',  "$tmp/stdin" or exit 126;
        open STDERR, '>&', \*STDOUT     or exit 126;
        exec $^X, @cmd or exit 127;
    }
    my $text = do { local $/ = undef; <$out> }
      // q{};
    close $out;
    return $text;
}

sub ping       { my (@args) = @_; return run( q{}, $ping,       @args ); }
sub traceroute { my (@args) = @_; return run( q{}, $traceroute, @args ); }

is( ping('192.0.2.1'),   "ping 192.0.2.1\n",    'ping: IPv4 host' );
is( ping('2001:db8::1'), "ping6 2001:db8::1\n", 'ping: IPv6 host uses ping6' );
is(
    ping(qw(192.0.2.1 count 3 size 100 quiet)),
    "ping -c 3 -s 100 -q 192.0.2.1\n",
    'ping: options translated'
);
is(
    ping(qw(192.0.2.1 ether-size 100)),
    "ping -s 72 192.0.2.1\n",
    'ping: ether-size less the IPv4 and ICMP headers'
);
is(
    ping(qw(2001:db8::1 ether-size 100)),
    "ping6 -s 52 2001:db8::1\n",
    'ping: ether-size less the IPv6 and ICMP headers'
);
is( ping(qw(192.0.2.1 interface lo1)),   "ping -Z lo1 192.0.2.1\n", 'ping: a loopback interface' );
is( ping(qw(192.0.2.1 interface dp0s3)), "ping -I dp0s3 192.0.2.1\n", 'ping: an interface' );
is( ping(qw(192.0.2.1 tos 16)),          "ping -Q 0x10 192.0.2.1\n",  'ping: decimal tos as hex' );
is( ping(qw(192.0.2.1 tos 0x10)),        "ping -Q 0x10 192.0.2.1\n",  'ping: hex tos kept' );
like( ping(qw(192.0.2.1 tos zz)), qr{not[ ]a[ ]valid}x, 'ping: bad tos refused' );
like(
    ping(qw(192.0.2.1 size 10 ether-size 100)),
    qr{cannot[ ]be[ ]specified[ ]together}x,
    'ping: size and ether-size refused'
);
like( ping(qw(192.0.2.1 bogus)), qr{unknown[ ]option[ ]bogus}x, 'ping: unknown option' );
like(
    ping(qw(192.0.2.1 count)),
    qr{missing[ ]argument[ ]for[ ]count}x,
    'ping: missing option argument'
);
like( ping(), qr{Missing[ ]host}x, 'ping: no host' );
is(
    ping(qw(192.0.2.1 routing-instance blue count 2)),
    "chvrf blue /opt/vyatta/bin/ping 192.0.2.1 count 2\n",
    'ping: re-run in the routing instance'
);
is(
    run( "dp0s3\n", $ping, 'fe80::1' ),
    "\nSpecify outgoing interface: ping6 -I dp0s3 fe80::1\n",
    'ping: link-local asks for the interface'
);

is( traceroute('192.0.2.1'),   "traceroute 192.0.2.1\n",      'traceroute: IPv4 host' );
is( traceroute('2001:db8::1'), "traceroute -6 2001:db8::1\n", 'traceroute: IPv6 host' );
is(
    traceroute(qw(ipv6 2001:db8::2 max-ttl 5 no-map)),
    "traceroute -6 -m 5 -n 2001:db8::2\n",
    'traceroute: ipv6 and options'
);
like(
    traceroute(qw(192.0.2.1 port)),
    qr{missing[ ]argument[ ]for[ ]port}x,
    'traceroute: missing option argument'
);
is(
    traceroute(qw(routing-instance blue 192.0.2.1)),
    "chvrf blue /opt/vyatta/bin/traceroute.pl 192.0.2.1\n",
    'traceroute: re-run in the routing instance'
);
is(
    run( "dp0s3\n", $traceroute, 'fe80::1' ),
    "\nSpecify outgoing interface: traceroute -6 -i dp0s3 fe80::1\n",
    'traceroute: link-local asks for the interface'
);
