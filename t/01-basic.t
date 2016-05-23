#!perl

use strict;
use warnings;

use Perinci::Sub::Util::ValidateArgs;
use Test::More 0.98;

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
    if (my $err = validate_args(\%args)) { return $err }
    [200, "OK"];
}

is_deeply(foo(),
          [400, "Missing required argument 'a1'"]);
is_deeply(foo(bar=>undef),
          [400, "Unknown argument 'bar'"]);
is_deeply(foo(a1=>1),
          [200, "OK"]);
is_deeply(foo(a1=>"x"),
          [400, "Validation failed for argument 'a1': Not of type integer"]);
is_deeply(foo(a1=>2, a2=>"x"),
          [400, "Validation failed for argument 'a2': Not of type array"]);
is_deeply(foo(a1=>2, a2=>["x"]),
          [400, "Validation failed for argument 'a2': \@[0]: Not of type integer"]);

# XXX test when result_naked=1

done_testing;
