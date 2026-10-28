# Test stub for Vyatta::Interface: dp0s3 is up and running with a
# description; any other name is up but down.
package Vyatta::Interface;
use strict;
use warnings;

sub new         { my ( $class, $name ) = @_; return bless { name => $name }, $class; }
sub up          { return 1; }
sub operstate   { my ($self) = @_; return $self->{name} eq 'dp0s3' ? 'up'     : 'down'; }
sub description { my ($self) = @_; return $self->{name} eq 'dp0s3' ? 'uplink' : undef; }

1;
