# Test stub for Vyatta::Misc: interfaces dp0s3 and dp0s4; dp0s3 has two
# addresses.
package Vyatta::Misc;
use strict;
use warnings;
use parent qw(Exporter);
## no critic (Modules::ProhibitAutomaticExportation) reason: the real module exports these by default
our @EXPORT = qw(getIP);

sub getInterfaces              { return qw(lo dp0s3 dp0s4); }
sub filter_link_local_loopback { return 1; }

sub getIP {
    my ($name) = @_;
    return $name eq 'dp0s3' ? ( '192.0.2.1/24', '2001:db8::1/64' ) : ();
}

1;
