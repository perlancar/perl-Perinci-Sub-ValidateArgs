#!perl

use 5.010001;
use strict;
use warnings;

use Perinci::Sub::ValidateArgs qw(gen_args_validator);
use Test::Exception;
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
            default => [1],
        },
    },
};
sub foo {
    state $validator = gen_args_validator();
    my %args = @_;
    if (my $err = $validator->(\%args)) { return $err }
    [200, "OK"];
}

$SPEC{foo_die} = $SPEC{foo};
sub foo_die {
    state $validator = gen_args_validator(die => 1);
    my %args = @_;
    $validator->(\%args);
    [200, "OK"];
}

subtest "basics" => sub {
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
};

# XXX test when result_naked=1

subtest "opt:die=1" => sub {
    dies_ok  { foo_die() };
    dies_ok  { foo_die(a1=>"x") };
    lives_ok { foo_die(a1=>2) };
};

done_testing;
