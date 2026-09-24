# Security

These contracts hold other people's money. If you find a way to take, freeze or misdirect it,
please tell us before you tell anyone else.

## Reporting a vulnerability

- Use GitHub's private vulnerability reporting on this repository
  (**Security → Report a vulnerability**), or
- send a direct message to [@davzer_](https://x.com/davzer_) on X.

Do not open a public issue for anything exploitable. Include the affected contract and function,
the conditions under which it triggers, and, if you have one, a Foundry test that reproduces it
against `test/shared/SweepForkTest.sol`. A reproduction shortens the fix by days.

You will get an acknowledgement within 48 hours and a fix timeline once the report is confirmed.
We ask that you give us a reasonable window to ship a fix before disclosing publicly, and we
will credit you in the fix commit unless you prefer otherwise.

## What has been done

- 275 Foundry tests: unit suites against mocks, fuzz and invariant suites, and fork suites that
  run every launch, trade, purchase, resale, burn and airdrop against the real Uniswap v4 on
  Robinhood Chain at a pinned block. CI runs all of them on every push.
- The one arbitrary external call in the protocol, `SweepNFTStrategy.buyTargetNFT`, is bounded by
  the bid and the treasury, refused when the venue is the collection itself, costed as a balance
  delta net of fees credited during the call, refused at zero cost, and followed by an assertion
  that the desk owns the exact piece it paid for.
- Nothing in the protocol is upgradeable. The launch liquidity is owned by the dead address.
