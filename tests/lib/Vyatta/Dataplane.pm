# Test stub for Vyatta::Dataplane: one dataplane whose "capture show"
# answer is the JSON in STUB_CAPTURE (none when unset).
package Vyatta::Dataplane;
use strict;
use warnings;
use parent qw(Exporter);
## no critic (Modules::ProhibitAutomaticExportation) reason: the real module exports these by default
our @EXPORT = qw(vplane_exec_cmd);

sub setup_fabric_conns { return ( [0], [1] ); }

sub vplane_exec_cmd { return ( [ $ENV{STUB_CAPTURE} ] ); }

1;
