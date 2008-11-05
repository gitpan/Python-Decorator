#-------------------------------------------------------------------
#
#   Python::Decorator - Python decorators for Perl5
#
#   $Id: Decorator.pm,v 1.4 2008-11-05 14:12:43 erwan Exp $
#

package Python::Decorator;

use strict;
use warnings;
use Carp qw(croak confess);
use Data::Dumper;
use PPI;
use PPI::Find;
use PPI::Token::Word;
use Filter::Util::Call;

our $VERSION = '0.01';

# import - just call filter_add from Filter::Util::Call
sub import {
    my ($class,%args) = @_;
    $class = ref $class || $class;

    my $self = bless({},$class);

    if (exists $args{debug}) {
	croak "import argument debug must be 0 or 1"
	    if ($args{debug} !~ /^(0|1)$/);
	$self->{debug} = $args{debug};
	delete $args{debug};
    }

    croak "unsupported import arguments: ".join(" ", keys %args)
	if (scalar keys %args);

    filter_add($self);
}

#
# filter - filter the source
#

# NOTE: we use PPI to parse the filtered source code instead of using
# simple regexps and support a smaller but standard subset of possible
# syntaxes for sub declaration. For just playing around with
# decorators, regexps would have been enough, but I also wanted to
# experiment using PPI in a source filter. Hence the extra headache :)

sub filter {
    my ($self) = @_;
    my $status;

    # read the whole source at once, accumulate it in $_
    do {
	$status = filter_read();
    } until ($status == 0);

    # TODO: croak here, or let Filter::Util::Call croak for us?
    croak "source filter error: $!"
	if ($status < 0);

    # special case: empty doc. nothing to do.
    return 0 if (length($_) == 0);

    # comment out python decorators since they are not parsable perl
    # and append a magic keyword (here '#DECORATOR:') in front of
    # them.  we later remove all those magic keywords. this is to
    # avoid commenting out valid perl code by misstake...
    while (s/^(\@\w+(\(.+\))?\s*)(\#.*)?$/\#DECORATOR:$1/gm) {}

    # parse the whole source with PPI
    my $doc = PPI::Document->new(\$_) ||
	croak "failed to parse source with PPI:".PPI::Document::errstr;

    # do not look for subs recursively: skip any anonymous sub declared within a sub.
    my $subs = $doc->find( sub {
	ref $_[1] ne '' && $_[1]->parent == $_[0] && $_[1]->isa('PPI::Statement::Sub');
    });

    if (ref $subs eq '') {
	# no subs declared in the source
	return 1;
    }

    # foreach sub declaration in the source file
    foreach my $esub (@$subs) {

	# find out the 'sub' keyword and the subroutine's name
	my @words = @{$esub->find('PPI::Token::Word')};

	confess "expected keyword 'sub'"
	    if ($words[0]->content ne 'sub');

	my $token_sub = $words[0];
	my $token_name = $words[1];
	my $subname = $token_name->content;

	confess "failed to parse sub name"
	    if (!defined $subname || $subname eq "");

	# look at lines just above the sub declaration: they might be
	# decorators
	my $prev = $esub->previous_token;
	my $before_sub = "";
	my $after_sub  = "";

	while (ref $prev eq 'PPI::Token::Comment' && $prev->content =~ /\#DECORATOR:/) {
	    my $c = $prev->content;

	    if ($c =~ /^\#DECORATOR:\@(\w+)\s*$/) {
		# previous line is a decorator that takes no arguments
		$before_sub = $1."(".$before_sub;
		$after_sub .= ")";
	    } elsif ($c =~ /^\#DECORATOR:\@(\w+\(.+\))\s*$/) {
		# previous line is a decorator that takes arguments
		$before_sub = $1."->(".$before_sub;
		$after_sub .= ")";
	    } else {
		# previous line looks like a decorator but is not...
		croak "invalid decorator syntax";
	    }

	    # remove the commented decorator but keep the newline to
	    # avoid messing up line-numbers in the source
	    $prev->set_content("\n");

	    # move up to previous line
	    $prev = $prev->previous_token;
	}

	# skip this sub if it has no decorators
	next if ($after_sub eq "");

	# now comes some source text manipulation by way of PPI.
	# we replace 'sub foo [...]' with something like:
	#
	# '{ no strict "refs"; *{__PACKAGE__."::foo"} = bar(bob(babe(sub [...] )))); }'
	#
	# the 'no strict "refs"' is needed for the symbol table
	# assignment '*{__PACKAGE__::foo} =' to work in a 'use strict'
	# environment.
	#
	# all those edits must fit on one line to avoid messing up the
	# linking between errors and line number.

	# remove the sub's name
	$token_name->set_content("");

	# replace the keyword 'sub' with the string below:
	$token_sub->set_content("{ no strict \"refs\"; *{__PACKAGE__.\"::".$subname."\"} = ".$before_sub." sub");

	# find the PPI block that contains the body of the subroutine
	my @blocks = @{ $esub->find( sub {
	    ref $_[1] ne '' && $_[1]->parent == $_[0] && $_[1]->isa('PPI::Structure::Block');
				     }) };

	croak "found no or more than 1 sub block for sub ".$self->subname
	    if (scalar @blocks != 1);

	my $subbody = $blocks[0];

	# replace the sub's last '}' with '} $after_sub; }'
	my $brace = $subbody->finish;
	confess "expected a '}' at the end of sub ".$subname
	    if ($brace->content ne "}");
	$brace->set_content("} $after_sub; }");
    }

    # serialize back the modified source tree
    $_ = $doc->serialize;

    # remove left over '#DECORATOR:'s
    while (s/^(\#DECORATOR:\@)/\@/gm) {}

    print "Python::Decorator filtered the source into:\n-------------------------------\n".$_."-------------------------------\n"
	if ($self->{debug});

    return 1;
}

1;

__END__

=head1 NAME

Python::Decorator - Function composition at compile-time

=head1 SYNOPSIS

This code:

    use Python::Decorator;
    [...]

    # add memoization to incr(). note the python-ish syntax with the
    # absence of ';' after the decorator
    @memoize
    sub incr {
	return $_[0]+1;
    }

is really just the same as this one:

    { 
        no strict 'refs';
        *{__PACKAGE__."::incr"} = memoize(
            sub { return $_[0]+1; }
        );
    }

In fact, the syntax:

    @memoize
    sub incr {

reads as: "before compiling C<incr()>, redefine C<incr()> to be the
function resulting from the composition of the function returned by
C<memoize()> applied to C<incr()>".

The function C<memoize()> takes a function to decorate and returns the
new decorated function.

As in Python, you can pass arguments to the decorator:

    @mylog("incr")  # log calls to incr()
    sub incr {
	return $_[0]+1;
    }

becomes:

    { 
        no strict 'refs';
        *{__PACKAGE__."::incr"} = mylog("incr")->(
            sub { return $_[0]+1; }
        );
    }

Notice that a decorator that takes arguments does not behave in the
same way as one that takes no arguments. In the case above, the
function C<mylog()> takes some arguments and returns a new no-argument
decorator, ie a function that takes a function to decorate and returns
the new decorated function. Though surprising at first, this behavior
is the same as in Python.

As in Python, you can apply multiple decorators to one subroutine:

    # replace incr by proxify(mylog(memoize(incr)))
    @proxify
    @mylog("incr")
    @memoize
    sub incr {
	return $_[0]+1;
    }
    
becomes:

    { 
        no strict 'refs';
        *{__PACKAGE__."::incr"} = proxify(mylog("incr")->(memoize(
            sub { return $_[0]+1; }
        )));
    }

Finally, if you want to see what Python::Decorator really does to the
source, call it with:

    use Python::Decorator debug => 1;

=head1 DESCRIPTION

Decorators are syntax sugar for function composition at compile-time.

Decorators were introduced in Python 2.4 (end of 2004) and have proven
since to provide functionality close to that of LISP macros. For a
complete description of decorators, ask google.

Python::Decorator implements the decorator syntax for Perl5, using
exactly the same syntax as in Python. It is a source filter, meaning
it manipulates source code before compilation. Decorated subroutines
are therefore composed at compile-time.

This module is a proof-of-concept in at least 2 ways:

=over 4

=item * There is no consensus as to which syntax macros or function
composition should have in Perl. Therefore Python::Decorator
implements decorators using Python's own syntax instead of trying to
introduce a more perlish syntax. If this module proves usefull,
someone will have to clone it into something more perlish.

=item * This module experiments using PPI to parse Perl5 source code
within a source filter. Though this is a slow and somewhat unstable
technic, I believe it's a way to go to get macros working in Perl.

=back

=head1 API

Those functions are for internal use only:

=over 4

=item C<import> Implements C<import> as required by Filter::Util::Call.

=item C<filter> Implements C<filter> as required by Filter::Util::Call.

=back

=head1 WARNING

Use in production code is REALLY NOT RECOMMENDED!

=head1 SEE ALSO

See PPI, Filter::Util::Call, Aspect.

=head1 BUGS

See PPI. Otherwise, report to the author!

=head1 VERSION

$Id: Decorator.pm,v 1.4 2008-11-05 14:12:43 erwan Exp $

=head1 AUTHORS

Erwan Lemonnier C<< <erwan@cpan.org> >>.

=head1 LICENSE

This code is provided under the Perl artistic license and comes with no warranty whatsoever.

=cut



