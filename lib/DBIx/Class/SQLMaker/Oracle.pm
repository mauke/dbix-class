package # Hide from PAUSE
  DBIx::Class::SQLMaker::Oracle;

use warnings;
use strict;

use base qw( DBIx::Class::SQLMaker );

BEGIN {
  use DBIx::Class::Optional::Dependencies;
  die('The following extra modules are required for Oracle-based Storages ' . DBIx::Class::Optional::Dependencies->req_missing_for ('id_shortener') . "\n" )
    unless DBIx::Class::Optional::Dependencies->req_ok_for ('id_shortener');
}

sub new {
  my $self = shift;
  my %opts = (ref $_[0] eq 'HASH') ? %{$_[0]} : @_;
  push @{$opts{special_ops}}, {
    regex => qr/^prior$/i,
    handler => '_where_field_PRIOR',
  };

  $self->next::method(\%opts);
}

sub _assemble_binds {
  my $self = shift;
  return map { @{ (delete $self->{"${_}_bind"}) || [] } } (qw/select from where oracle_connect_by group having order limit/);
}


sub _parse_rs_attrs {
    my $self = shift;
    my ($rs_attrs) = @_;

    my ($cb_sql, @cb_bind) = $self->_connect_by($rs_attrs);
    push @{$self->{oracle_connect_by_bind}}, @cb_bind;

    my $sql = $self->next::method(@_);

    return "$cb_sql $sql";
}

sub _connect_by {
    my ($self, $attrs) = @_;

    my $sql = '';
    my @bind;

    if ( ref($attrs) eq 'HASH' ) {
        if ( $attrs->{'start_with'} ) {
            my ($ws, @wb) = $self->_recurse_where( $attrs->{'start_with'} );
            $sql .= $self->_sqlcase(' start with ') . $ws;
            push @bind, @wb;
        }
        if ( my $connect_by = $attrs->{'connect_by'} || $attrs->{'connect_by_nocycle'} ) {
            my ($connect_by_sql, @connect_by_sql_bind) = $self->_recurse_where( $connect_by );
            $sql .= sprintf(" %s %s",
                ( $attrs->{'connect_by_nocycle'} ) ? $self->_sqlcase('connect by nocycle')
                    : $self->_sqlcase('connect by'),
                $connect_by_sql,
            );
            push @bind, @connect_by_sql_bind;
        }
        if ( $attrs->{'order_siblings_by'} ) {
            $sql .= $self->_order_siblings_by( $attrs->{'order_siblings_by'} );
        }
    }

    return wantarray ? ($sql, @bind) : $sql;
}

sub _order_siblings_by {
    my ( $self, $arg ) = @_;

    my ( @sql, @bind );
    for my $c ( $self->_order_by_chunks($arg) ) {
        $self->_SWITCH_refkind(
            $c,
            {
                SCALAR   => sub { push @sql, $c },
                ARRAYREF => sub { push @sql, shift @$c; push @bind, @$c },
            }
        );
    }

    my $sql =
      @sql
      ? sprintf( '%s %s', $self->_sqlcase(' order siblings by'), join( ', ', @sql ) )
      : '';

    return wantarray ? ( $sql, @bind ) : $sql;
}

# we need to add a '=' only when PRIOR is used against a column diretly
# i.e. when it is invoked by a special_op callback
sub _where_field_PRIOR {
  my ($self, $lhs, $op, $rhs) = @_;
  my ($sql, @bind) = $self->_recurse_where ($rhs);

  $sql = sprintf ('%s = %s %s ',
    $self->_convert($self->_quote($lhs)),
    $self->_sqlcase ($op),
    $sql
  );

  return ($sql, @bind);
}

# use this codepath to hook all identifiers and mangle them if necessary
# this is invoked regardless of quoting being on or off
sub _quote {
  my ($self, $label) = @_;

  return '' unless defined $label;
  return ${$label} if ref($label) eq 'SCALAR';

  $label =~ s/ ( [^\.]{31,} ) /$self->_shorten_identifier($1)/gxe;

  $self->next::method($label);
}

# this takes an identifier and shortens it if necessary
# optionally keywords can be passed as an arrayref to generate useful
# identifiers
sub _shorten_identifier {
  my ($self, $to_shorten, $keywords) = @_;

  # 30 characters is the identifier limit for Oracle
  my $max_len = 30;
  # we want at least 10 characters of the base36 md5
  my $min_entropy = 10;

  my $max_trunc = $max_len - $min_entropy - 1;

  return $to_shorten
    if length($to_shorten) <= $max_len;

  $self->throw_exception("'keywords' needs to be an arrayref")
    if defined $keywords && ref $keywords ne 'ARRAY';

  # if no keywords are passed use the identifier as one
  my @keywords = @{$keywords || []};
  @keywords = $to_shorten unless @keywords;

  # get a base36 md5 of the identifier
  require Digest::MD5;
  require Math::BigInt;
  require Math::Base36;
  my $b36sum = Math::Base36::encode_base36(
    Math::BigInt->from_hex (
      '0x' . Digest::MD5::md5_hex ($to_shorten)
    )
  );

  # switch from perl to java
  # get run-length
  my ($concat_len, @lengths);
  for (@keywords) {
    $_ = ucfirst (lc ($_));
    $_ =~ s/\_+(\w)/uc ($1)/eg;

    push @lengths, length ($_);
    $concat_len += $lengths[-1];
  }

  # if we are still too long - try to disemvowel non-capitals (not keyword starts)
  if ($concat_len > $max_trunc) {
    $concat_len = 0;
    @lengths = ();

    for (@keywords) {
      $_ =~ s/[aeiou]//g;

      push @lengths, length ($_);
      $concat_len += $lengths[-1];
    }
  }

  # still too long - just start cuting proportionally
  if ($concat_len > $max_trunc) {
    my $trim_ratio = $max_trunc / $concat_len;

    for my $i (0 .. $#keywords) {
      $keywords[$i] = substr ($keywords[$i], 0, int ($trim_ratio * $lengths[$i] ) );
    }
  }

  my $fin = join ('', @keywords);
  my $fin_len = length $fin;

  return sprintf ('%s_%s',
    $fin,
    substr ($b36sum, 0, $max_len - $fin_len - 1),
  );
}

sub _unqualify_colname {
  my ($self, $fqcn) = @_;

  return $self->_shorten_identifier($self->next::method($fqcn));
}

#
# Oracle has a different INSERT...RETURNING syntax
#

sub _insert_returning {
  my ($self, $options) = @_;

  my $f = $options->{returning};

  my ($f_list, @f_names) = $self->_SWITCH_refkind($f, {
    ARRAYREF => sub {
      (join ', ', map { $self->_quote($_) } @$f),
      @$f
    },
    SCALAR => sub {
      $self->_quote($f),
      $f,
    },
    SCALARREF => sub {
      $$f,
      $$f,
    },
  });

  my $rc_ref = $options->{returning_container}
    or $self->throw_exception('No returning container supplied for IR values');

  @$rc_ref = (undef) x @f_names;

  return (
    ( join (' ',
      $self->_sqlcase(' returning'),
      $f_list,
      $self->_sqlcase('into'),
      join (', ', ('?') x @f_names ),
    )),
    map {
      $self->{bindtype} eq 'columns'
        ? [ $f_names[$_] => \$rc_ref->[$_] ]
        : \$rc_ref->[$_]
    } (0 .. $#f_names),
  );
}


{
  my %part_map = (
    second       => 'SECOND',
    minute       => 'MINUTE',
    hour         => 'HOUR',
    day_of_month => 'DAY',
    month        => 'MONTH',
    year         => 'YEAR',
  );

  sub _datetime_sql {
    my ($self, $part, $date) = @_;

    die $self->_unsupported_date_extraction($part, 'Oracle')
       unless exists $part_map{$part};

    my $rhs = $date eq '?' ? "TO_TIMESTAMP($date)" : $date;

    return "EXTRACT($part_map{$_[1]} FROM $rhs)";
  }
}

{
  my %part_map = (
    second       => '* 31 * 24 * 60 * 60',
    minute       => '* 31 * 24 * 60',
    hour         => '* 31 * 24',
    day          => '* 31',
    month        => undef,
    year         => '/ 12',
  );

  sub _datetime_diff_sql {
    die $_[0]->_unsupported_date_diff($_[1], 'Oracle')
       unless exists $part_map{$_[1]};
    my $sql = "MONTHS_BETWEEN($_[2], $_[3])";
    $sql .= " $part_map{$_[1]}"
      if defined $part_map{$_[1]};
    $sql = "TRUNC($sql)";
    return $sql;
  }
}

{
  my %part_map = (
    second       => 'NUMTODSINTERVAL',
    minute       => 'NUMTODSINTERVAL',
    hour         => 'NUMTODSINTERVAL',
    day          => 'NUMTODSINTERVAL',
    month        => 'NUMTOYMINTERVAL',
    year         => 'NUMTOYMINTERVAL',
  );

  sub _datetime_add_sql {
    my ($self, $part, $date, $amount) = @_;

    die $self->_unsupported_date_adding($part, 'Oracle')
      unless exists $part_map{$part};

    my $rhs = $date eq '?' ? "TO_TIMESTAMP($date)" : $date;

    return "($rhs + $part_map{$part}($amount, '$part'))";
  }
}

sub _reorder_add_datetime_vars {
   my ($self, $amount, $date) = @_;

   return ($date, $amount);
}

=head1 DATE FUNCTION IMPLEMENTATION

The function used to extract date information is C<EXTRACT>, which supports

 second
 minute
 hour
 day_of_month
 month
 year

The function used to diff dates is C<MONTHS_BETWEEN> with
multiplication/division to the requested format.
The valid formats are:

 second
 minute
 hour
 day
 month
 year

=cut

1;
