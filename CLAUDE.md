# langsys-ruby

The framework-agnostic Ruby base SDK for Langsys. Framework wrappers (`langsys-ruby-rails`)
build on top of it and are separate repos.

## Commits

Do not add trailers to commit messages — no `Co-Authored-By`, no `Claude-Session`, no
`Generated with`. Fleet convention across the Langsys SDK repos, so history reads the same
in all of them.

## Conformance

Behaviour is governed by the SDK Behaviour Spec, read from git rather than the website:

```
cd ../langsys2 && git show origin/main:docs/sdk-spec.mdx
```

`CONFORMANCE.md` maps every rule id to the test that proves it. A rule with no test is **not
implemented** — that is a fact about this SDK, not a documentation gap. This SDK's profile is
`server` + `all`; `browser` and `binding` rules do not apply here.

When changing behaviour a rule governs, update its row and its evidence tier in the same
commit.

## Testing

```
bundle exec rake spec         # unit, hermetic (WebMock blocks the network)
bundle exec rake integration  # live, needs a local backend — see below
bundle exec rubocop
bundle exec rake rbs
```

The live suite needs credentials, and the GATE examples need one key per type because the
whole point of the rule is that the same project answers differently per key:

```
LANGSYS_PROJECT_ID=… LANGSYS_API_KEY=… LANGSYS_API_URL=http://langsys2.test/api \
  LANGSYS_READ_KEY=… LANGSYS_IPWRITE_KEY=… bundle exec rake integration
```

Those keys are seeded by langsys2's `SdkIntegrationSeeder`. Run
`php artisan db:seed --class=SdkIntegrationSeeder` there — **never** `migrate:fresh --seed`,
which drops tables other lanes depend on.

Note `spec_helper` allows the `LANGSYS_API_URL` host past WebMock: `allow_localhost` does not
count a Valet `.test` domain as localhost, and without this the live suite fails at the socket
layer in a way that looks exactly like a credentials problem.

## House norms

- **Red-first per behaviour.** Write the failing assertion before the fix.
- **Check the verifier.** A negative result needs a positive control — prove the test can fail.
- **Mutation over inspection.** Before claiming a defence works, break the behaviour and show
  the intended assertions go red. Most defects here were found by executing code, none by
  reading it.
