#!/usr/bin/perl
# Tests for the YANG RPC scripts yangop-ping.pl, yangop-route.pl and
# yangop-interface.pl: JSON in on stdin, JSON (or a command) out. ping and
# yangop-get-route are stubs; the RPC values must reach them as arguments,
# never through a shell.
#
# SPDX-License-Identifier: GPL-2.0-only

use strict;
use warnings;
use File::Temp qw(tempdir);
use FindBin;
use JSON;
use Test::More tests => 10;

my $tmp = tempdir( CLEANUP => 1 );
chdir $tmp or BAIL_OUT("chdir: $!");

sub write_file {
    my ( $file, $content, $mode ) = @_;
    open my $fh, '>', $file or BAIL_OUT("cannot write $file: $!");
    print {$fh} $content;
    close $fh or BAIL_OUT("cannot close $file: $!");
    chmod $mode, $file if defined $mode;
    return;
}

sub copy_script {
    my ( $name, $from, $to ) = @_;
    open my $in, '<', "$FindBin::Bin/../scripts/$name" or BAIL_OUT("$name: $!");
    my $script = do { local $/ = undef; <$in> };
    close $in or BAIL_OUT("$name: $!");
    $script =~ s{\Q$from\E}{$to}gx if defined $from;
    write_file( "$tmp/$name", $script );
    return "$tmp/$name";
}

write_file( "$tmp/ping", <<'END', oct 755 );
#!/bin/sh
for a; do printf '%s|' "$a" >> args.log; done; echo >> args.log
echo "PING 192.0.2.1 56(84) bytes of data."
echo ""
echo "--- 192.0.2.1 ping statistics ---"
echo "3 packets transmitted, 2 received, 33% packet loss, time 2003ms"
echo "rtt min/avg/max/mdev = 0.351/1.722/3.093/1.371 ms"
END
write_file( "$tmp/yangop-get-route", "#!/bin/sh\nfor a; do printf '%s|' \"\$a\"; done; echo\n",
    oct 755 );
my $ping = copy_script( 'yangop-ping.pl', '/opt/vyatta/bin/ping', "$tmp/ping" );
my $route =
  copy_script( 'yangop-route.pl', '/opt/vyatta/bin/yangop-get-route', "$tmp/yangop-get-route" );
my $intf = copy_script('yangop-interface.pl');

sub rpc {
    my ( $script, $input ) = @_;
    write_file( "$tmp/in.json", encode_json($input) );
    unlink "$tmp/args.log";
    my $pid = open my $out, '-|';
    defined $pid or BAIL_OUT("fork: $!");
    if ( !$pid ) {
        open STDIN, '<', "$tmp/in.json" or exit 126;
        exec $^X, "-I$FindBin::Bin/lib", $script or exit 127;
    }
    my $text = do { local $/ = undef; <$out> }
      // q{};
    close $out;
    return $text;
}

sub logged {
    open my $fh, '<', "$tmp/args.log" or return q{};
    my $text = do { local $/ = undef; <$fh> };
    close $fh;
    return $text;
}

is_deeply(
    decode_json( rpc( $ping, { host => '192.0.2.1', count => 3 } ) ),
    {
        'tx-packet-count' => 3,
        'rx-packet-count' => 2,
        'min-delay'       => 0,
        'average-delay'   => 1,
        'max-delay'       => 3
    },
    'ping: statistics parsed'
);
is( logged(), "192.0.2.1|count|3|quiet|\n", 'ping: options passed, quietly' );

rpc( $ping, { host => '192.0.2.1;touch pwned1', count => '1;touch pwned2' } );
ok( !-e 'pwned1' && !-e 'pwned2', 'ping: RPC values are not run by a shell' );
is(
    logged(),
    "192.0.2.1;touch pwned1|count|1;touch pwned2|quiet|\n",
    'ping: RPC values are single arguments'
);

is( rpc( $route, {} ), "\n", 'route: IPv4 table by default' );
is( rpc( $route, { family => 'ipv6', destination => '2001:db8::/32' } ),
    "-6|-r|2001:db8::/32|\n", 'route: family and destination' );
is(
    rpc( $route, { destination => '192.0.2.0/24;touch pwned3' } ),
    "-r|192.0.2.0/24;touch pwned3|\n",
    'route: the destination is one argument'
);
ok( !-e 'pwned3', 'route: the destination is not run by a shell' );

is_deeply(
    decode_json( rpc( $intf, { name => 'dp0s3' } ) ),
    {
        address        => [ { ip => '192.0.2.1/24' }, { ip => '2001:db8::1/64' } ],
        'admin-status' => 'up',
        'oper-status'  => 'up',
        description    => 'uplink'
    },
    'interface: state'
);
like( rpc( $intf, { name => 'dp0s9' } ), qr{^$}x, 'interface: unknown name gives no state' );
