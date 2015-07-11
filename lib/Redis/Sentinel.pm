package Redis::Sentinel;

# ABSTRACT: Redis Sentinel interface

use warnings;
use strict;

use Carp;

use base qw(Redis);

sub new {
    my ($class, %args) = @_;
    # these args are not allowed when contacting a sentinel
    delete @args{qw(sentinels service)};

    $class->SUPER::new(%args);
}

sub get_service_address {
    my ($self, $service) = @_;
    my ($ip, $port) = $self->sentinel('get-master-addr-by-name', $service);
    defined $ip
      or return;
    $ip eq 'IDONTKNOW'
      and return $ip;
    return "$ip:$port";
}

sub get_masters {
    map { +{ @$_ }; } @{ shift->sentinel('masters') || [] };
}

sub get_slaves {
    my @slaves;

    eval {@slaves = map { +{@$_}; } @{ shift->sentinel('slaves', shift) || [] }; 1 } or do {
      die unless $@ =~ m/ERR No such master with that name/;
      return;
    };

    return \@slaves;
}

1;

__END__

=head1 SYNOPSIS

    my $sentinel = Redis::Sentinel->new( ... );
    my $service_address = $sentinel->get_service_address('mymaster');
    my @masters = $sentinel->get_masters;

=head1 DESCRIPTION

This is a subclass of the Redis module, specialized into connecting to a
Sentinel instance. Inherits from the C<Redis> package;

=head1 CONSTRUCTOR

=head2 new

See C<new> in L<Redis.pm>. All parameters are supported, except C<sentinels>
and C<service>, which are silently ignored.

=head1 METHODS

All the methods of the C<Redis> package are supported, plus the additional following methods:

=head2 get_service_address

Takes the name of a service as parameter, and returns either void (emptly list)
if the master couldn't be found, the string 'IDONTKNOW' if the service is in
the sentinel config but cannot be reached, or the string C<"$ip:$port"> if the
service were found.

=head2 get_masters

Returns a list of HashRefs representing all the master redis instances that
this sentinel monitors.

=head2 get_slaves

Takes the name of a service as parameter.

If the service is not known to the sentinels server, returns undef. If
the service is known, retuns an arrayRef of hashRef's, one for each
slave available on the service.

=cut
