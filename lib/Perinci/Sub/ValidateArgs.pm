package Perinci::Sub::ValidateArgs;

# NOIFBUILT
# DATE
# VERSION

use strict 'subs', 'vars';
use warnings;

use Data::Sah;

use Exporter qw(import);
our @EXPORT = qw(validate_args);

my %validator_cache; # key = schema (C<string> or R<refaddr>), value = validator

sub validate_args {
    my $args = shift;

    my @caller = caller(1);
    my ($pkg, $func) = $caller[3] =~ /(.+)::(.+)/;
    my $meta = ${"$pkg\::SPEC"}{$func}
        or die "No metadata for $caller[3]";
    ($meta->{args_as} || 'hash') eq 'hash'
        or die "Metadata for $caller[3]: only args_as=hash ".
        "supported";
    my $args_spec = $meta->{args} or return undef;
    my $result_naked = $meta->{result_naked};
    my $err;

    for my $arg_name (keys %$args) {
        unless (exists $args_spec->{$arg_name}) {
            $err = "Unknown argument '$arg_name'";
            if ($result_naked) { die $err } else { return [400, $err] }
        }
    }

    for my $arg_name (keys %$args_spec) {
        my $arg_spec = $args_spec->{$arg_name};
        if ($arg_spec->{req} && !exists($args->{$arg_name})) {
            $err = "Missing required argument '$arg_name'";
            if ($result_naked) { die $err } else { return [400, $err] }
        }
        if (!defined($args->{$arg_name}) && defined($arg_spec->{default})) {
            $args->{$arg_name} = $arg_spec->{default};
        }
        next unless exists $args->{$arg_name};
        my $schema = $arg_spec->{schema} or next;
        my $cache_key = ref($schema) ? "R:$schema" : "S:$schema";
        my $validator = $validator_cache{$cache_key};
        if (!$validator) {
            $validator = Data::Sah::gen_validator(
                $schema, {return_type=>'str'});
            $validator_cache{$cache_key} = $validator;
        }
        $err = $validator->($args->{$arg_name});
        if ($err) {
            $err = "Validation failed for argument '$arg_name': $err";
            if ($result_naked) { die $err } else { return [400, $err] }
        }
    }
    # TODO: check args_rels
    return undef;
}

1;
# ABSTRACT: Validate function arguments using schemas in Rinci function metadata

=head1 SYNOPSIS

 #IFUNBUILT
 use Perinci::Sub::ValidateArgs;
 #END IFUNBUILT

 our %SPEC;
 $SPEC{foo} = {
     v => 1.1,
     args => {
         a1 => {
            schema => 'int*',
            req => 1,
         },
         a2 => {
             schema => [array => of=>'int*'],
             default => 'peach',
         },
     },
     'x.func.validate_args' => 1,
 };
 sub foo {
     my %args = @_; # VALIDATE_ARGS
     # IFUNBUILT
     if (my $err = validate_args(\%args)) { return $err }
     # END IFUNBUILT

     ...
 }


=head1 DESCRIPTION

This module (PSV for short) can be used to validate function arguments using
schema information in Rinci function metadata. Schemas will be checked using
L<Data::Sah> validators which are generated on-demand and then cached.

An alternative to this module is L<Dist::Zilla::Plugin::Rinci::Validate>
(DZP:RV), where during build, the C<# VALIDATE_ARGS> directive will be filled
with generated validator code.

Using DZP:RV is faster (see/run the benchmark in
L<Bencher::Scenario::PerinciSubValidateArgs::Overhead>) and avoid dependencies
on Data::Sah itself, but you need to build your code as a proper distribution
first and use the built version. Using PSV is slower (up to several times, plus
there is a startup overhead of compiling the Data::Sah validators the first time
the function is called) and makes you dependent on Data::Sah during runtime, but
is more flexible because you don't have to build your code as a distribution
first.

A strategy can be made using L<Dist::Zilla::Plugin::IfBuilt>. You mark the PSV
parts with C<#IFUNBUILT> and C<#END IFUNBUILT> directives so the PSV part is
only used in the unbuilt version, while the built/production version uses the
faster DZP:RV. But this still requires you to organize your code as a proper
distribution.

BTW, yet another alternative is to use L<Perinci::CmdLine::Lite> or
L<Perinci::CmdLine::Inline>. These two frameworks can generate the argument
validator code for you. But this only works if you access your function via CLI
using the frameworks.

And yet another alternative is L<Perinci::Sub::Wrapper> (PSW) which wraps your
function with code to validate arguments (among others). PSW is used by
L<Perinci::CmdLine::Classic>, for example.

If you use DZP:RV and/or PSV, you might want to set Rinci metadata attribute
C<x.func.validate_args> to true to express that your function body performs
argument validation. This hint is used by PSW or the Perinci::CmdLine::*
frameworks to skip (duplicate) argument validation.


=head1 FUNCTIONS

All the functions are exported by default.

=head2 validate_args(\%args) => $err

Get Rinci function metadata from caller's C<%SPEC> package variable. Then create
(and cache) a set of L<Data::Sah> validators to check the value of each argument
in C<%args>. If there is an error, will return an error response C<$err> (or
die, if C<result_naked> metadata property is true). Otherwise will return undef.

Arguments in C<%args> will have their default values/coercions/filters applied,
so they are ready for use.

Currently only support C<< args_as => 'hash' >> (the default).


=head1 SEE ALSO

L<Rinci>, L<Data::Sah>

L<Dist::Zilla::Plugin::IfBuilt>

L<Dist::Zilla::Plugin::Rinci::Validate>
