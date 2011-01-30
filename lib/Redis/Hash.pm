package Redis::Hash;

use strict;
use warnings;
use Tie::Hash;
use base qw/Redis Tie::StdHash/;

=head1 NAME

Redis::Hash - tie perl hashes into Redis

=head1 SYNOPSYS

    ## Create fake hash using keys like 'hash_prefix:KEY'
    tie %my_hash, 'Redis::Hash', 'hash_prefix', @Redis_new_parameters;
    
    ## Treat the entire Redis database as a hash
    tie %my_hash, 'Redis::Hash', undef, @Redis_new_parameters;
    
    $value = $my_list{$key};
    $my_list{$key} = $value;
    
    @keys   = keys %my_hash;
    @values = values %my_hash;
    
    %my_hash = reverse %my_hash;
    
    %my_hash = ();


=head1 DESCRIPTION

Ties a Perl hash to Redis. Note that it doesn't use Redis Hashes, but
implements a fake hash using regular keys like "prefix:KEY".

If no C<prefix> is given, it will tie the entire Redis database
as a hash.

Future versions will also allow you to use real Redis hash structures.


=cut


sub TIEHASH {
  my ($class, $prefix, @rest) = @_;
  my $self = $class->new(@rest);

  $self->{prefix} = $prefix ? "$prefix:" : '';

  return $self;
}

sub STORE {
  my ($self, $key, $value) = @_;
  $self->set($self->{prefix} . $key, $value);
}

sub FETCH {
  my ($self, $key) = @_;
  $self->get($self->{prefix} . $key);
}

sub FIRSTKEY {
  my $self = shift;
  $self->{prefix_keys} = [$self->keys($self->{prefix} . '*')];
  $self->NEXTKEY;
}

sub NEXTKEY {
  my $self = shift;

  my $key = shift @{$self->{prefix_keys}};
  return unless defined $key;

  my $p = $self->{prefix};
  $key =~ s/^$p// if $p;
  return $key;
}

sub EXISTS {
  my ($self, $key) = @_;
  $self->exists($self->{prefix} . $key);
}

sub DELETE {
  my ($self, $key) = @_;
  $self->del($self->{prefix} . $key);
}

sub CLEAR {
  my ($self) = @_;
  $self->del($_) for $self->keys($self->{prefix} . '*');
  $self->{prefix_keys} = [];
}

1;
