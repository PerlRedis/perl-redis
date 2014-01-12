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

1;
