package CPAN::Faker;
use 5.008;
use Moose;

=head1 NAME

CPAN::Faker - build a bogus CPAN instance for testing

=head1 VERSION

version 0.003

=cut

our $VERSION = '0.003';

use CPAN::Checksums ();
use Compress::Zlib ();
use Cwd ();
use File::Next ();
use File::Path ();
use File::Spec ();
use Module::Faker::Dist;
use Sort::Versions qw(versioncmp);
use Text::Template;

=head1 SYNOPSIS

  use CPAN::Faker;

  my $cpan = CPAN::Faker->new({
    source => './eg',
    dest   => './will-contain-fakepan',
  });

  $cpan->make_cpan;

=head1 DESCRIPTION

First things first: this is a pretty special-needs module.  It's for people who
are writing tools that will operate against a copy of the CPAN (or something
just like it), and who need data to test those tools against.

Because the real CPAN is constantly changing, and a mirror of the CPAN is a
pretty big chunk of data to deal with, CPAN::Faker lets you build a fake
CPAN-like directory tree out of simple descriptions of the distributions that
should be in your fake CPAN.

=head1 THE CPAN INTERFACE

A CPAN instance is just a set of files in known locations.  At present,
CPAN::Faker will create the following files:

  ./authors/01mailrc.txt.gz            - the list of authors (PAUSE ids)
  ./modules/02packages.details.txt.gz  - the master index of current modules
  ./modules/03modlist.txt.gz           - the "registered" list; has no data
  ./authors/id/X/Y/XYZZY/Dist-1.tar.gz - each distribution in the archive
  ./authors/id/X/Y/XYZZY/CHECKSUMS     - a CPAN checksums file for the dir

Note that while the 03modlist file is created, for the sake of the CPAN client, 
the file contains no data about registered modules.  This may be addressed in
future versions.

Other files that are not currently created, but may be in the future are:

  ./indices/find-ls.gz
  ./indices/ls-lR.gz
  ./modules/06perms.txt.gz
  ./modules/by-category/...
  ./modules/by-module/...

If there are other files that you'd like to see created (or if you want to ask
to get the creation of one of the above implemented soon), please contact the
current maintainer (see below).

=head1 METHODS

=head2 new

  my $faker = CPAN::Faker->new(\%arg);

This create the new CPAN::Faker.  All arguments may be accessed later by
methods of the same name.  Valid arguments are:

  source - the directory in which to find source files
  dest   - the directory in which to construct the CPAN instance
  url    - the base URL for the CPAN; a file:// URL is generated by default

  dist_class - the class used to fake dists; default: Module::Faker::Dist

=cut

has _pkg_index => (
  is  => 'ro',
  isa => 'HashRef',
  default  => sub { {} },
  init_arg => undef,
);

has _author_index => (
  is  => 'ro',
  isa => 'HashRef',
  default  => sub { {} },
  init_arg => undef,
);

has _author_dir => (
  is  => 'ro',
  isa => 'HashRef',
  default  => sub { {} },
  init_arg => undef,
);

has source => (is => 'ro', isa => 'Str', required => 1);
has dest   => (is => 'ro', isa => 'Str', required => 1);

has dist_dest => (
  is   => 'ro',
  lazy => 1,
  init_arg => undef,
  default  => sub { File::Spec->catdir($_[0]->dest, qw(authors id)) },
);

has dist_class => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
  default  => sub { 'Module::Faker::Dist' },
);

has url => (
  is      => 'ro',
  isa     => 'Str',
  default => sub {
    my ($self) = @_;
    my $url = "file://" . File::Spec->rel2abs($self->dest);
    $url =~ s{(?<!/)$}{/};
    return $url;
  },
);

sub BUILD {
  my ($self) = @_;

  for (qw(source dest)) {
    my $dir = $self->$_;
    Carp::croak "$_ directory does not exist"     unless -e $dir;
    Carp::croak "$_ directory is not a directory" unless -d $dir;
    Carp::croak "$_ directory is not writeable"   unless -w $dir;
  }
}

sub __dor { defined $_[0] ? $_[0] : $_[1] }

=head2 make_cpan

  $faker->make_cpan;

This method makes the CPAN::Faker do its job.  It iterates through all the
files in the source directory and builds a distribution object.  Distribution
archives are written out into the author's directory, distribution contents are
(potentially) added to the index, CHECKSUMS files are created, and the indices
are then written out.

=head2 write_author_index

=head2 write_package_index

=head2 write_modlist_index

All these are automatically called by C<make_cpan>; you probably do not need to
call them yourself.

Write C<01mailrc.txt.gz>, C<02packages.details.txt.gz>, and
C<03modlist.data.gz>, respectively.

=cut

sub make_cpan {
  my ($self, $arg) = @_;

  my $iter = File::Next::files($self->source);

  while (my $file = $iter->()) {
    my $dist = $self->dist_class->from_file($file);
    $self->add_dist($dist);
  }

  $self->_update_author_checksums;

  $self->write_package_index;
  $self->write_author_index;
  $self->write_modlist_index;
}

sub add_dist {
  my ($self, $dist) = @_;

  my $archive = $dist->make_archive({
    dir           => $self->dist_dest,
    author_prefix => 1,
  });

  $self->_learn_author_of($dist);
  $self->_maybe_index($dist);

  my ($author_dir) =
    $dist->archive_filename({ author_prefix => 1 }) =~ m{\A(.+)/};

  $self->_author_dir->{ $author_dir } = 1;
}

sub _update_author_checksums {
  my ($self) = @_;

  my $dist_dest = File::Spec->catdir($self->dest, qw(authors id));

  for my $dir (keys %{ $self->_author_dir }) {
    $dir = File::Spec->catdir($dist_dest, $dir);
    CPAN::Checksums::updatedir($dir);
  }
}

sub _learn_author_of {
  my ($self, $dist) = @_;
  
  my ($author) = $dist->authors;
  my $pauseid = $dist->cpan_author;

  return unless $author and $pauseid;

  $self->_author_index->{$pauseid} = $author;
}

sub _maybe_index {
  my ($self, $dist) = @_;

  my $index = $self->_pkg_index;

  PACKAGE: for my $package ($dist->provides) {
    my $entry = { dist => $dist, pkg => $package };

    if (my $existing = $index->{ $package->name }) {
      my $e_dist = $existing->{dist};
      my $e_pkg  = $existing->{pkg};

      if (defined $package->version and not defined $e_pkg->version) {
        $index->{ $package->name } = $entry;
        next PACKAGE;
      } elsif (not defined $package->version and defined $e_pkg->version) {
        next PACKAGE;
      } else {
        my $pkg_cmp = versioncmp($package->version, $e_pkg->version);

        if ($pkg_cmp == 1) {
          $index->{ $package->name } = $entry;
          next PACKAGE;
        } elsif ($pkg_cmp == 0) {
          if (versioncmp($dist->version, $e_dist->version) == 1) {
            $index->{ $package->name } = $entry;
            next PACKAGE;
          }
        }

        next PACKAGE;
      }
    } else {
      $index->{ $package->name } = $entry;
    }
  }
}

sub write_author_index {
  my ($self) = @_;

  my $index = $self->_author_index;

  my $index_dir = File::Spec->catdir($self->dest, 'authors');
  File::Path::mkpath($index_dir);

  my $index_filename = File::Spec->catfile(
    $index_dir,
    '01mailrc.txt.gz',
  );

  my $gz = Compress::Zlib::gzopen($index_filename, 'wb');

  for my $pauseid (sort keys %$index) {
    $gz->gzwrite(qq{alias $pauseid "$index->{$pauseid}"\n})
      or die "error writing to $index_filename"
  }

  $gz->gzclose and die "error closing $index_filename";
}

sub write_package_index {
  my ($self) = @_;

  my $index = $self->_pkg_index;

  my @lines;
  for my $pkg_name (sort keys %$index) {
    my $pkg = $index->{ $pkg_name }->{pkg};
    push @lines, sprintf "%-34s %5s  %s\n",
      $pkg->name,
      __dor($pkg->version, 'undef'),
      $index->{ $pkg_name }->{dist}->archive_filename({ author_prefix => 1 });
  }

  my $front = $self->_front_matter({ lines => scalar @lines });

  my $index_dir = File::Spec->catdir($self->dest, 'modules');
  File::Path::mkpath($index_dir);

  my $index_filename = File::Spec->catfile(
    $index_dir,
    '02packages.details.txt.gz',
  );

  my $gz = Compress::Zlib::gzopen($index_filename, 'wb');
  $gz->gzwrite("$front\n");
  $gz->gzwrite($_) || die "error writing to $index_filename" for @lines;
  $gz->gzclose and die "error closing $index_filename";
}

sub write_modlist_index {
  my ($self) = @_;

  my $index_dir = File::Spec->catdir($self->dest, 'modules');

  my $index_filename = File::Spec->catfile(
    $index_dir,
    '03modlist.data.gz',
  );

  my $gz = Compress::Zlib::gzopen($index_filename, 'wb');
  $gz->gzwrite($self->_template->{modlist});
  $gz->gzclose and die "error closing $index_filename";
}

my $template;
sub _template {
  return $template if $template;

  my $current;
  while (my $line = <DATA>) {
    chomp $line;
    if ($line =~ /\A__([^_]+)__\z/) {
      my $filename = $1;
      if ($filename !~ /\A(?:DATA|END)\z/) {
        $current = $filename;
        next;
      }
    }

    Carp::confess "bogus data section: text outside of file" unless $current;

    ($template->{$current} ||= '') .= "$line\n";
  }

  return $template;
}

sub _front_matter {
  my ($self, $arg) = @_;

  my $template = $self->_template->{packages};

  my $text = Text::Template->fill_this_in(
    $template,
    DELIMITERS => [ '{{', '}}' ],
    HASH       => {
      self => \$self,
      (map {; $_ => \($arg->{$_}) } keys %$arg),
    },
  );

  return $text;
}

=head1 COPYRIGHT AND AUTHOR

This distribution was written by Ricardo Signes, E<lt>rjbs@cpan.orgE<gt>.

Copyright 2008.  This is free software, released under the same terms as perl
itself.

=cut

no Moose;
1;

__DATA__
__packages__
File:         02packages.details.txt
URL:          {{ $self->url }}modules/02packages.details.txt.gz
Description:  Package names found in directory $CPAN/authors/id/
Columns:      package name, version, path
Intended-For: Automated fetch routines, namespace documentation.
Written-By:   CPAN::Faker version {{ $CPAN::Faker::VERSION }}
Line-Count:   {{ $lines }}
Last-Updated: {{ scalar localtime }}
__modlist__
File:        03modlist.data
Description: CPAN::Faker does not provide modlist data.
Modcount:    0
Written-By:  CPAN::Faker version {{ $CPAN::Faker::VERSION }}
Date:        {{ scalar localtime }}

package CPAN::Modulelist;
# Usage: print Data::Dumper->new([CPAN::Modulelist->data])->Dump or similar
# cannot 'use strict', because we normally run under Safe
# use strict;
sub data {
my $result = {};
my $primary = "modid";
for (@$CPAN::Modulelist::data){
my %hash;
@hash{@$CPAN::Modulelist::cols} = @$_;
$result->{$hash{$primary}} = \%hash;
}
$result;
}
$CPAN::Modulelist::cols = [
'modid',
'statd',
'stats',
'statl',
'stati',
'statp',
'description',
'userid',
'chapterid'
];
$CPAN::Modulelist::data = [];
