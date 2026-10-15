# STUDENT-QUESTIONS.md — Discussion questions (goes inside your submission zip)

Answer directly under each question. 150–300 words each — **reasoning over length**.

The sections follow the four planks of the bridge. There are no standard answers; these are the
real point of the lab.

---

## A. Custody — where the asset actually is (plank a)

**A1.** In Lab 1, `totalCollateral()` read the vault's own ERC-20 balance, and the chain could
prove the invariant. Here, `MockTBillCustodian.realHoldings()` is just a number that a permissioned
address can move. Write the equivalent of `totalCollateral() == totalSupply()` for *this* system.
What does it actually assert, and what does it no longer prove?

> Your answer:


I would compare the value of the assets with the value of the claims, rather than compare raw token amounts. Before any redemption requests, the ideal relation is:

```text
vault.reserveBalance() + custodian.realHoldings()
    == vault.totalClaimValue()
```

Both sides use six decimal places. The claim value is `totalSupply * NAV / 1e20`, because shares have 18 decimals and NAV has eight. Using `>=` instead expresses sufficient backing rather than an exact accounting match.

Once there are redemption tickets, the calculation needs more care. Escrowed shares remain in total supply until settlement, but their payouts are already fixed. Therefore, liabilities are the current value of nonqueued shares, plus `pendingAssets`, plus `totalClaimable`. Assets must also include the USDC held by the queue. This avoids counting the same redemption twice.

Even if these numbers match, they only show consistency between on-chain cash and reported figures. An authorised custodian can increase `realHoldings()` without receiving any assets, and the reporter can change NAV. The equation does not prove that the T-Bills exist, belong to the fund, are free of other claims, or can be sold when needed. Those facts still require independent custody records and checks. The lab does not enforce this backing relation.

**A2.** The T-Bills are held by an SPV, a legal entity set up so the fund's assets are bankruptcy-
remote from the issuer. Explain in your own words why a *legal* structure is part of a *technical*
design. If the SPV's custodian goes bankrupt, what does the on-chain token entitle its holder to?

> Your answer:

A smart contract can record my shares, but it cannot make a bank hand over Treasury bills. The legal structure explains who owns the assets, who owes me payment, and how those rights can be enforced. That is why it is part of the system design.

An SPV keeps the fund's assets legally separate from the issuer's ordinary business. If that separation is valid and maintained, the issuer's creditors should not simply take the fund's T-Bills. However, protection from the issuer's bankruptcy does not remove the risk of the custodian failing.

If the custodian becomes insolvent, my rights depend on the fund documents, custody agreement and applicable law. Properly segregated securities should be recoverable for the SPV rather than used to pay the custodian's general creditors. My token represents the rights defined by the fund, which may include a share of recovered assets or redemption proceeds. It does not automatically give me direct ownership of a particular T-Bill or guarantee immediate payment at par. [OECD's discussion of tokenised-asset custody](https://www.oecd.org/content/dam/oecd/en/publications/reports/2021/03/regulatory-approaches-to-the-tokenisation-of-assets_da7ae482/aea35466-en.pdf) highlights this uncertainty over investor property rights.

Recovery can still involve delays, costs and losses if assets are missing. A correct token balance cannot fix a missing or unenforceable legal claim.

---

## B. Attestation — how the chain learns the truth (plank b)

**B1.** `attest()` is the only function that moves the NAV, and it is gated by `REPORTER_ROLE`.
Everything downstream — subscription pricing, redemption payouts, both invariants — believes that
number. Name the failure modes of a single trusted reporter, and one mechanism (technical,
financial, or legal) that mitigates each.

> Your answer:

A single reporter can fail in several ways. First, an honest person may enter the wrong price or use the wrong decimal scale. An independent calculation and reasonable limits on price changes can catch many mistakes. Large changes should trigger review rather than be accepted automatically.

Second, someone may steal the reporting key. Hardware-protected keys, approvals from several independent signers, and a clear process for revoking compromised keys reduce this risk. Third, the reporter may deliberately lie or collude with a trader. Independent price sources, regular reconciliation with custody records, and legal responsibility make this harder. Several signatures are not enough if all signers rely on the same false information.

Fourth, the reporter may stop updating. The system should check the actual observation time, alert operators, and stop accepting orders at stale prices until a trustworthy update is available.

The queue invariants do not establish that NAV is honest. Shares can be correctly escrowed and settled claims fully funded while the payout price is unfair.

There is also a limitation in this implementation: `attest()` checks `REPORTER_ROLE`, but `MockPriceFeed.setPrice()` is public and unrestricted. Anyone can call the feed directly. A production version must restrict that entry point as well; protecting only the vault function is insufficient.

**B2.** A production feed would check whether `updatedAt` is stale; this lab's mock does not. A
**frozen** NAV is a different attack from a **wrong** NAV. Describe how a stale-but-honest NAV can
be exploited by someone who knows the true value has moved.

> Your answer:

A stale price can be accurate for yesterday but unfair for a trade today. The attacker does not need to change the oracle; they only need better information than the price currently used by the fund.

Suppose the displayed NAV is $1, while the true value has risen to $1.10. An informed buyer can subscribe with $1,000 and receive 1,000 shares instead of about 909.09 shares. If the higher value remains, those shares become worth more when NAV is updated. The new buyer benefits at the expense of existing holders through dilution.

The reverse happens when the true value falls. If NAV still shows $1 while the assets are worth $0.90 per share, a holder can enqueue 1,000 shares and lock a $1,000 payout. Updating NAV later does not reduce that ticket. Remaining holders bear the shortfall, while the redeemer still faces settlement delays if cash is unavailable.

I would use a maximum permitted price age and price orders at a published dealing time. Stale orders should wait for a valid price. A backup feed must also be fresh and independently reliable.

In this mock, `latestRoundData()` returns the current `block.timestamp` on every read. Checking that timestamp alone would miss a frozen price. The feed must store when the value was actually observed or updated.

---

## C. Redemption — T+1 does not settle on-chain (plank c)

**C1.** The queue locks the payout at the NAV of **enqueue** time, not **settle** time. If the NAV
rises between the two, who gains and who loses — the redeemer, or the holders who stayed? Is that
the right allocation of risk, and how would you change it?

> Your answer:

If the asset value rises after enqueue, the redeemer still receives the amount locked earlier. For example, 1,000 shares queued at $1 receive $1,000 even if NAV reaches $1.25 before settlement. The redeemer gives up the later $250 increase. Economically, that extra value remains in the fund for the holders who stayed. If asset values fall instead, the fixed payout protects the redeemer and leaves more of the loss with the remaining holders, assuming the fund can honour the promise.

I think fixing a price is reasonable if everyone knows exactly when their market exposure ends. However, fixing it at an old NAV while the assets remain invested creates an advantage for people who expect losses and exit first. The redeemer also still bears the risk of a delayed or unpaid settlement.

I would price requests at the next announced dealing time using a fresh NAV, then lock the amount and reserve cash or sell the corresponding assets. Selling costs should be disclosed and charged fairly. Existing tickets should not be silently repriced.

This is the economic allocation; the lab does not automatically recalculate the remaining holders' NAV from net assets. Also, a NAV increase is not a USDC deposit. Extra value may sit in T-Bills at the custodian, so `vault.reserveBalance() >= queue.pendingAssets()` is not a reliable invariant.

**C2.** In a 2008 money-market fund breaking the buck, and in USDC's 2023 depeg, redemptions were
handled very differently. Compare the two. For a tokenized T-Bill fund, what does it mean to "close
the redemption channel", and what should happen to the queue when it does? Then look at the lever
this lab actually ships: `pause()` (`PAUSER_ROLE`) freezes transfers, minting **and** redemption
together — one switch, no partial setting. Why is that the wrong tool for a liquidity squeeze, and
what would you rather have?

> Your answer:

In 2008, the Reserve Primary Fund broke the buck when its NAV fell to $0.97. The SEC allowed redemptions to be suspended while assets were liquidated in an orderly way. Investors had to wait for distributions instead of receiving immediate payment at $1. [SEC account](https://www.sec.gov/divisions/investment/guidance/reservefundmmffaq.htm).

USDC's March 2023 depeg involved uncertainty about $3.3 billion of reserves at Silicon Valley Bank and limited weekend access to bank settlement. Tokens could still trade on-chain below $1. After authorities protected the bank's depositors, Circle retained its 1:1 redemption commitment and processing resumed when banks reopened. This was a temporary disruption, rather than a fund liquidation. [Circle announcement](https://www.circle.com/pressroom/3-3-billion-of-usdc-reserve-risk-removed-dollar-de-peg-closes), [Federal Reserve explanation](https://www.chicagofed.org/publications/chicago-fed-letter/2026/519).

For this fund, closing redemption should mean a clearly defined restriction on new requests or settlement. Existing tickets should remain recorded with their locked amounts and FIFO order. Operators should publish the reason and reopening conditions, and settle only when cash is available. Already funded claims should normally remain withdrawable.

A token-wide pause is too broad for a cash shortage: it also stops ordinary transfers and subscriptions that might supply liquidity. I would separate controls for subscriptions, new redemption requests and settlement, while preserving funded claims unless a separate security or legal issue requires otherwise.

The actual code has an important distinction: pausing tBILL blocks enqueue transfers and settlement burns, but `queue.claim()` only transfers USDC. Therefore, already settled claims remain payable even while tBILL is paused.

---

## D. Admission — the guest list and the backdoor (plank d)

**D1.** Every balance change in `TBillToken._update` checks **both** endpoints against the
whitelist. That is what stops a sanctioned address from receiving shares — and also what stops a
completely ordinary user who has not finished KYC. Where is the right line for a regulated fund,
and who should be able to move it?

> Your answer:

For a regulated fund, I think eligibility should follow clear legal requirements and the fund's published rules. Identity checks, sanctions screening and any applicable investor restrictions are reasonable conditions. However, an ordinary applicant who is still completing KYC should have a practical route to approval, with clear requirements and a way to challenge mistakes.

In this contract, `_update` checks every nonzero sender and receiver. This covers minting, transfers and burns, so a whitelisted investor cannot bypass the receiver's checks by sending shares to an unapproved wallet. Removing someone from the whitelist freezes their existing shares; it does not erase their balance. The rule is enforced by code, but the decision about who qualifies is still made off-chain.

I would assign `COMPLIANCE_ROLE` to an accountable compliance team with approvals from more than one authorised person. The fund's governance should approve major policy changes under the applicable law. Neither an anonymous token vote nor one developer should be able to rewrite eligibility at will.

Changes should produce audit records, while personal identity documents stay off-chain. Urgent freezes may need to happen quickly, but they should have documented reasons and independent review. This keeps necessary controls while reducing arbitrary exclusion and privacy risks.

**D2.** A regulated fund asks for two levers: freeze an address (`setWhitelisted(addr, false)`) and
burn a balance (`MINTER_ROLE`) — both censorship tools, both justified by the product. But Ex4.3
shows the two **collide**: once an address is off the list, `burn()` reverts as well, because
`_update` guards both endpoints. So a freeze also blocks a seizure. Argue **both** sides of handing
an issuer these powers, then say what safeguards you would add and who should hold each key.

> Your answer:

There are reasonable arguments for both powers. A freeze can stop a compromised wallet from moving stolen shares or help the fund obey a lawful restriction. A narrowly controlled burn or recovery process may help correct an invalid issuance or implement a court decision. Without these tools, some errors become difficult to reverse.

However, the same powers can be abused. An issuer could silence a holder, freeze an innocent user after a mistaken screening result, or destroy someone's investment. A compromised key could cause similar damage. Also, burning shares does not automatically compensate the owner or transfer value to a rightful recipient.

Ex4.3 shows that a frozen holder cannot currently be burned because `burn()` also passes through the whitelist check. This blocks seizure while the freeze remains in place. It is not a complete safeguard: someone controlling the relevant roles can restore the whitelist entry and then burn. Freezing an owner after enqueue also does not necessarily block redemption, because settlement burns the queue's shares and claim pays USDC.

I would separate compliance, ordinary issuance and exceptional seizure permissions. The compliance team would control freezes; routine minting and redemption burns would be limited to the vault and queue. Exceptional seizure would require a documented legal basis and independent multisignature approval, with notice and appeal where legally possible. Role administration must have equally strong protection, or it can bypass those limits.


---

## E. Tests (Tier 1 required — this is Ex2, Ex3 and Ex4)

Turn the red tests green in `test/exercises/01_BridgeTasks.t.sol` to cover the scenarios below, and
write your test function names here:

| Plank | Scenario | Your test function name |
|---|---|---|
| a | Shares exist while the custodian holds nothing | `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` |
| a | `realHoldings()` moves with no cash moving | `test_Ex2_RealHoldingsIsJustANumber` |
| b | The claim value floats while the share count stays | `test_Ex3_TheClaimFloats_TheShareCountDoesNot` |
| b | One `attest` re-prices every holder at once | `test_Ex3_OneCallMovesTheWholeBook` |
| d | A non-whitelisted address cannot receive shares, even by paying | `test_Ex4_NoKyc_NoShares_EvenIfYouPay` |
| d | A whitelisted holder cannot send shares to a non-whitelisted address | `test_Ex4_TransferChecksBothEndpoints` |
| d | Removing an address freezes that holder — and blocks a burn | `test_Ex4_FreezeBeatsConfiscation` |

Then write one more scenario you consider **most likely to be exploited** on a tokenized fund, and
say which plank it breaks:

> Your answer:

My choice is NAV manipulation through a compromised or poorly protected price update path. It breaks plank (b), attestation, because the contracts use the reported price without checking the actual assets.

For example, Alice first deposits 1,000 USDC at NAV $1. An attacker sets NAV to $0.50 and subscribes another 1,000 USDC, receiving 2,000 shares. After restoring NAV to $1, the attacker queues those shares for a 2,000 USDC payout. If an authorised settler processes the request while the vault has enough cash, the attacker can claim both deposits. Alice still holds 1,000 shares, but the cash backing them is gone. The existing `test_falseNav()` demonstrates this sequence; its player also holds `SETTLER_ROLE`, so settlement permission is not bypassed.

I would prioritise this risk because a valid transaction and correct queue accounting can still produce an unfair payout. In a real fund, the entry point could be a stolen reporter key. This mock is even weaker: anyone can call `MockPriceFeed.setPrice()` directly. I would restrict every price update path, require independent price checks, and investigate large NAV changes before accepting new orders.
