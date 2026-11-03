# Personal data

What the backend and the phone hold about a person, why, and for how long. This is a working list to base a privacy policy on, not legal advice. The retention periods are suggestions, not final.

The test `the data list covers every column` in `backend/test/extras.test.ts` fails if the database gets a column that isn't listed here.

## On the backend

| Data | Where | Why it's kept | How long (suggested) |
| --- | --- | --- | --- |
| `users.id` | users | A random id for the account | Until the account is deleted |
| `users.apple_user_id` | users | Apple's stable id for the person, so Sign in with Apple finds the same account again. It isn't an email or a name | Until the account is deleted |
| `users.age_confirmed_at` | users | Proof the person confirmed they're old enough | Until the account is deleted |
| `users.terms_version` | users | Which terms the person accepted | Until the account is deleted |
| `users.terms_accepted_at` | users | When they accepted | Until the account is deleted |
| `users.leave_requested_at` | users | So the leave wait survives a reinstall | Until the account is deleted |
| `users.created_at` | users | When the account began | Until the account is deleted |
| `payments.id` | payments | A random id for the record | The tax retention period |
| `payments.user_id` | payments | Links a payment to the account, so the person sees their history and the daily limit works | Emptied when the account is deleted |
| `payments.apple_transaction_id` | payments | Apple's id for the purchase. Lets us match refunds and ignore a purchase sent twice | The tax retention period |
| `payments.product_id` | payments | Which product was bought | The tax retention period |
| `payments.amount_minor` | payments | What was paid, for the books | The tax retention period |
| `payments.currency` | payments | The currency of that amount | The tax retention period |
| `payments.status` | payments | Paid or refunded | The tax retention period |
| `payments.purchased_at` | payments | Apple's purchase time. The daily limit is counted from this | The tax retention period |
| `payments.refunded_at` | payments | When Apple refunded it | The tax retention period |
| `unlocks.id` | unlocks | A random id for the record | Deleted with the account |
| `unlocks.payment_id` | unlocks | Which payment the unlock came from | Deleted with the account |
| `unlocks.started_at` | unlocks | When the unlock started | Deleted with the account |
| `unlocks.ends_at` | unlocks | When it ended | Deleted with the account |
| `pending_refunds.apple_transaction_id` | pending_refunds | A refund notice that arrived before its payment, kept until the payment shows up | Until matched |
| `pending_refunds.refunded_at` | pending_refunds | When Apple said it was refunded | Until matched |

The tax retention period depends on the country and needs an accountant. After an account is deleted, payment rows stay without any link to the person.

## In the logs

The log files hold request lines and errors. They carry the random user id on a few lines (account created, account deleted, payment over the limit). They don't hold names, email addresses, tokens or purchase contents. Two files of at most 25 MB each are kept, so old lines fall off on their own.

## In backups

Nightly copies of the database, 14 kept. A deleted account can stay in a backup for up to 14 days.

## On the phone

Kept in the app's own storage and the shared app group. It never leaves the phone, apart from the purchases waiting in the queue.

- Whether the block is on, the end of the current unlock, and the start times of recent unlocks
- When leaving started, if it has
- Purchases waiting to reach the backend
- The backend's last answer about the time and today's unlock count
- The session token, in the Keychain
- Apple's private tokens for what's blocked. We can't read them

## What we never store

- Which apps or sites are blocked, or how long any app is used
- Name, email address, phone number or location
- Why someone joined
- Card details

## Who else gets the data

- **Apple** runs the sign in and the payments, and tells the backend about purchases and refunds.
- **The hosting provider** for the VM will hold the backend (provider not chosen yet). A data processing agreement is needed.

## The person's rights

- **A copy:** Settings, then "Get a copy of my data", or `GET /v1/me/export`. It returns the account row and the payment history as JSON.
- **Deletion:** Settings, then "Delete my account now", or `DELETE /v1/me`.
- **Revoking Sign in with Apple on deletion** is not built yet. It needs an Apple signing key.
