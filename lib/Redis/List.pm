package Redis::List;

# ABSTRACT: tie Perl arrays to Redis lists
our $VERSION = '1.961'; # VERSION
our $AUTHORITY = 'cpan:MELO'; # AUTHORITY

use strict;
use warnings;
use base qw/Redis Tie::Array/;


sub TIEARRAY {
  my ($class, $list, @rest) = @_;
  my $self = $class->new(@rest);

  $self->{list} = $list;

  return $self;
}

sub FETCH {
  my ($self, $index) = @_;
  $self->lindex($self->{list}, $index);
}

sub FETCHSIZE {
  my ($self) = @_;
  $self->llen($self->{list});
}

sub STORE {
  my ($self, $index, $value) = @_;
  $self->lset($self->{list}, $index, $value);
}

sub STORESIZE {
  my ($self, $count) = @_;
  $self->ltrim($self->{list}, 0, $count);

#		if $count > $self->FETCHSIZE;
}

sub CLEAR {
  my ($self) = @_;
  $self->del($self->{list});
}

sub PUSH {
  my $self = shift;
  my $list = $self->{list};

  $self->rpush($list, $_) for @_;
}

sub POP {
  my $self = shift;
  $self->rpop($self->{list});
}

sub SHIFT {
  my ($self) = @_;
  $self->lpop($self->{list});
}

sub UNSHIFT {
  my $self = shift;
  my $list = $self->{list};

  $self->lpush($list, $_) for @_;
}

sub SPLICE {
  my ($self, $offset, $length) = @_;
  $self->lrange($self->{list}, $offset, $length);

  # FIXME rest of @_ ?
}

sub EXTEND {
  my ($self, $count) = @_;
  $self->rpush($self->{list}, '') for ($self->FETCHSIZE .. ($count - 1));
}

sub DESTROY { $_[0]->quit }

1;    ## End of Redis::List

__END__

=pod

=encoding utf-8

=for :stopwords Pedro Melo ACKNOWLEDGEMENTS

=head1 NAME

Redis::List - tie Perl arrays to Redis lists

=head1 VERSION

version 1.961

=head1 SYNOPSYS

    tie @my_list, 'Redis::List', 'list_name', @Redis_new_parameters;

    $value = $my_list[$index];
    $my_list[$index] = $value;

    $count = @my_list;

    push @my_list, 'values';
    $value = pop @my_list;
    unshift @my_list, 'values';
    $value = shift @my_list;

    ## NOTE: fourth parameter of splice is *NOT* supported for now
    @other_list = splice(@my_list, 2, 3);

    @my_list = ();

=head1 AUTHOR

Pedro Melo <melo@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Pedro Melo.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut
