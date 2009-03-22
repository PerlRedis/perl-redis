package Redis::Hash;

use strict;
use warnings;

use Tie::Hash;
use base qw/Redis Tie::StdHash/;

=head1 NAME

Redis::Hash - tie perl hashes into Redis

=head1 SYNOPSYS

  tie %$name, 'Redis::Hash', 'name';

=cut

# mandatory methods
sub TIEHASH {
	my ($class,$name) = @_;
	my $self = $class->new;
	$self->{name} = $name || '';
	bless $self => $class;
}

sub STORE {
	my ($self,$key,$value) = @_;
	$self->set( $self->{name} . $key, $value );
}

sub FETCH {
	my ($self,$key) = @_;
	$self->get( $self->{name} . $key );
}

sub FIRSTKEY {
	my $self = shift;
	$self->{keys} = [ $self->keys( $self->{name} . '*') ];
	unshift @{ $self->{keys} };
} 

sub NEXTKEY {
	my $self = shift;
	unshift @{ $self->{keys} };
}

sub EXISTS {
	my ($self,$key) = @_;
	$self->exists( $self->{name} . $key );
}

sub DELETE {
	my ($self,$key) = @_;
	$self->del( $self->{name} . $key );
}

sub CLEAR {
	my ($self) = @_;
	$self->del( $_ ) foreach ( $self->keys( $self->{name} . '*' ) );
}

1;
