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
        next unless exists $args->{$arg_name};
        my $schema = $arg_spec->{schema} or next;
        my $cache_key = ref($schema) ? "R:$schema" : "S:$schema";
        my $validator = $validator_cache{$cache_key};
        if (!$validator) {
            $validator = Data::Sah::gen_validator(
                $schema, {return_type=>'str+val'});
            $validator_cache{$cache_key} = $validator;
        }
        if (!defined($args->{$arg_name}) && defined($arg_spec->{default})) {
            $args->{$arg_name} = $arg_spec->{default};
        }
        ($err, $args->{$arg_name}) = @{ $validator->($args->{$arg_name}) };
        if ($err) {
            $err = "Validation failed for argument '$arg_name': $err";
            if ($result_naked) { die $err } else { return [400, $err] }
        }
    }
    # TODO: check args_rels
    return undef;
}

1;
# ABSTRACT: Validate function arguments

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
 };
 sub foo {
     my %args = @_;
     # IFUNBUILT
     if (my $err = validate_args(\%args)) { return $err }
     # END IFUNBUILT

     ...
 }


=head1 DESCRIPTION

This is an experimental module to ease validating function arguments for
unwrapped function.


=head1 FUNCTIONS

All the functions are exported by default.

=head2 validate_args(\%args) => $err

Get Rinci function metadata from caller's C<%SPEC> package variable. Then create
(and cache) a set of L<Data::Sah> validator to check the value of each argument.
If there is an error, will return an error response C<$err>. Otherwise will
return undef.

Arguments in C<%args> will have their default values/coercions/filters applied,
so they are ready for use.

Currently only support C<< args_as => 'hash' >> (the default).


=head1 SEE ALSO

L<Rinci>, L<Data::Sah>

L<Dist::Zilla::Plugin::IfBuilt>
