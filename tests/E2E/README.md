# ERPNext end-to-end tests (testRigor)

Plain-English UI tests for ERPNext, run with [testRigor](https://testrigor.com).

## Layout

- `test-cases/*.yaml`: one test per file. The file name is the test name; `customSteps` holds the steps and `labels` the tags.
- `rules/*.txt`: reusable steps. The file name is the rule name, so a test can call `log in as administrator`.
- `variables.json`: stored values used by the steps (`erpnextUser`, `erpnextPassword`).
- `ci/`: a throwaway stack for CI and local runs (`run-e2e.sh`, `compose.yml`, `install-erpnext.sh`); see below.

## What the tests expect

A site set up like `ci/install-erpnext.sh` does: company "E2E Test Co" (USD, "US ST 6%" sales tax), customers "E2E Seed Customer A/B", supplier "E2E Seed Supplier A", items E2E-SEED-001/002/003 selling at 25 / 40 / 99.50 and buying at 20 / 30 / 80, with stock in "Stores - ETC", and English as the browser language (the login page follows the browser's language).

| Test | Covers |
|---|---|
| create customer | Login, Selling module navigation, new Customer saved |
| sales order to sales invoice | Sales Order with a seeded customer and item, submit, Create > Sales Invoice, submit; checks the 6% tax total |
| sales order to delivery note | Sales Order for E2E-SEED-001, submit, Create > Delivery Note, submit (status To Bill); View > Stock Ledger shows Out Qty -1.000 from "Stores - ETC" |
| receive payment for a sales invoice | Accounts module, new Sales Invoice, submit (Unpaid), Create > Payment fills in 42.40, submit; back on the invoice the status is Paid |
| create item with a selling rate | Stock module, Add Item > Edit Full Form, Standard Selling Rate creates an Item Price; a new Sales Order picks up that rate |
| purchase order to purchase invoice | Buying module, Purchase Order for E2E-SEED-001 at the $ 20.00 buying price, submit (To Receive and Bill), Create > Purchase Receipt, submit (To Bill), Create > Purchase Invoice, submit (Unpaid, Outstanding $ 21.20); back on the receipt the status is Completed |
| material request to purchase order | Stock module, Material Request (Purchase) for E2E-SEED-003, submit (Pending), Create > Purchase Order copies the item, add the supplier, submit (To Receive and Bill, $ 80.00 buying price, Grand Total $ 84.80); back on the request the status is Ordered |
| transfer stock between warehouses | Stock module, Stock Entry of type Material Transfer: 2 x E2E-SEED-002 from "Stores - ETC" to "Work In Progress - ETC", Total Outgoing Value $ 80.00, submit; View > Stock Ledger shows -2.000 from Stores and the Work In Progress row |
| bom to work order to finished goods | Manufacturing module, BOM for E2E-SEED-003 from E2E-SEED-001 + E2E-SEED-002, submit (Default), Create > Work Order with "Stores - ETC" as the default source warehouse, submit (Not Started); Start > material transfer entry, submit (In Process); Finish > manufacture entry, submit; back on the work order the status is Completed |
| balanced journal entry | Accounts module, Journal Entry via Quick Entry: $ 150.00 debit to "Miscellaneous Expenses - ETC" and credit to "Cash - ETC", save (Draft, both rows filled), submit; View > Ledger (General Ledger) shows both accounts at $ 150.00 |

## Running against a local instance

```bash
testrigor test-suite run <suite-id> --auth-token <token> \
    --localhost --url http://localhost:8080 \
    --explicit-mutations \
    --test-cases-path 'tests/E2E/test-cases/*.yaml' \
    --rules-path 'tests/E2E/rules/*.txt' \
    --variables-path tests/E2E/variables.json
```

`--localhost` opens a tunnel so testRigor's browsers can reach the local site. `--explicit-mutations` makes the suite run exactly the tests in this folder.

## Running on a throwaway stack (CI)

`ci/run-e2e.sh` does the whole run: it starts a fresh ERPNext stack with Docker Compose (`ci/compose.yml`, frappe_docker's quick-start services), provisions the site with `ci/install-erpnext.sh` (setup wizard, preferences and the seed data above), runs the suite through the tunnel, saves the JUnit report, and removes the stack. The workflow `.github/workflows/e2e-testrigor.yml` calls it, and it runs the same way on a laptop:

```bash
TESTRIGOR_AUTH_TOKEN=<token> TESTRIGOR_SUITE_ID=<suite-id> bash tests/E2E/ci/run-e2e.sh
```

- By default it runs the published `frappe/erpnext:develop` image. `BUILD_REPO=https://github.com/<owner>/erpnext BUILD_BRANCH=<branch>` builds an image from that branch first (frappe_docker's layered image), which is how the workflow tests the code in the repository.
- `HTTP_PORT` (default 8080) and `COMPOSE_PROJECT` (default `erpnext-e2e-ci`) let it run next to another instance. `KEEP_STACK=1` leaves the stack up for debugging. On failure the container logs are saved next to the report (`ARTIFACTS_DIR`, default `tests/E2E/ci/artifacts`).
- The workflow runs nightly and from the Actions tab, not on pull requests: workflows triggered by pull requests from forks cannot read secrets. It needs a `TESTRIGOR_AUTH_TOKEN` secret and a `TESTRIGOR_SUITE_ID` variable. Runs are serialized because each run syncs the suite to this folder.

## Notes

- The tests only click through the UI from the start page; they never open URLs directly, so they work through the tunnel.
- Frappe splits the label of page action buttons to underline their Alt shortcut (`<span class="alt-underline">A</span>dd Customer`, also Save, Submit and Cancel). testRigor's normal text match cannot find these, so the tests click them with `using OCR only`. Dialog buttons (Yes, No, the quick-entry Save) and the Create toggle have plain labels.
- Create-menu items split a mnemonic letter the same way (`<span>S</span>ales Invoice`). OCR with a relative anchor fails there, so the tests click the remaining text (`click "ales Invoice"`, `"elivery Note"`, `"ayment"`, `"urchase Receipt"`, `"urchase Order"`, `"rchase Invoice"`, `"ork Order"`, `"edger"` (the journal entry View menu) (its mnemonic is the second letter, P<u>u</u>rchase Invoice), and `"tock Ledger"` in the View menu), which only the menu item contains as a separate text node.
- "Add Customer" opens a quick-entry dialog. After saving, the list does not refresh until you open another list and come back.
- Some action buttons are not found by OCR either ("Add Item", "Add Material Request"; the tests also use this for "Add Stock Entry"). Clicking the text after the underlined letter works, the same as for menu items: `click "dd Item"`, `click "dd Material Request"`, `click "dd Stock Entry"`, `click "dd BOM"`, `click "dd Journal Entry"`.
- Frappe keeps pages you have visited in the DOM, hidden. The Item form leaves a hidden HTML `<table>` behind, and testRigor then uses it for `click on table ...` instead of the div-based items grid of a later form. A `reload` before opening the next form clears those pages.
- "Add Item" opens a quick-entry dialog without the selling rate; "Edit Full Form" carries the Item Code over to the full form.
- To check text built from a stored value, use `string with parameters "${itemCode}, Products"`. `stored value "x" itself + "..."` is not valid; testRigor rewrites it with AI into a check that never matches.
- Link fields (Customer) accept the exact value followed by Tab. In the items grid, `click on table at row "1" and column "Item Code"` opens the cell; after typing, wait for the dropdown option (`"E2E-SEED-002, Products"`), then click it or press Enter (the first match is highlighted). Tab can fire before the search results arrive.
- The delivery note test takes 1 unit of E2E-SEED-001 from "Stores - ETC" per run (seeded with 100). It checks the ledger row for its own delivery note, not the balance, so it is not affected by other runs until the stock runs out; reinstall the site to reset.
- Editable currency fields show the bare number (`42.40`); the `$ ` prefix only appears once the field is read-only. Check editable amounts with `check that input "Paid Amount (USD)" has value "42.40"`.
- Tab out of the Purchase Order "Supplier" field lands on "Date" and opens its date picker, which covers the "Required By" field below it; `enter ... into "Required By"` then silently sets nothing and Save fails with "Required By is required in every row". `press Escape` after the Tab closes the picker. The header "Required By" is copied to the item rows.
- The Purchase Receipt timeline keeps the text "To Bill" after the status turns Completed, so the test checks for "Completed" rather than the absence of "To Bill". The same goes for the Material Request: its timeline keeps "Pending" after it turns Ordered.
- Stock Entry Type: `enter` + Tab does not commit the link in testRigor. Wait for the dropdown (`"Material Transfer for Manufacture"`, the second option) and `press Enter` to pick the highlighted "Material Transfer". Warehouse cells: type part of the name (`"Stores"`), wait for the full option (`"Stores - ETC"`), press Enter.
- In a grid, Tab out of the last column (Stock Entry "Qty") adds an empty row that blocks saving ("Item Code is required in row 2"). Escape does not commit the value either: the next Save click only commits the cell and does not save. Commit by clicking another cell: `click on table at row "1" and column "Basic Rate (as per Stock UOM)"`.
- testRigor's `enter` leaves the field, so a partial link value (`"Stores"`) is rejected ("Stores did not match any results") and cleared; the dropdown then lists every warehouse and Enter picks the first one. In header link fields, enter the exact value (`"Stores - ETC"`), press Tab, and check it with `check that input "Default source Warehouse" has value "Stores - ETC"`. (In grid cells, `type` keeps the focus, so typing part of the name and pressing Enter works there.)
- Work orders need a source warehouse for every raw material; the seed items have no default warehouse, so the test fills "Default source Warehouse" on the work order. The WIP and Finished Goods warehouses come from the company defaults that `install-erpnext.sh` sets.
- The Work Order, Start and Finish dialogs have a "Create" button while the page behind them has a "Create" menu. Anchor the dialog button to the dialog's full-width field label: `click "Create" below "Qty To Manufacture"`. A narrow anchor ("Max: 1", the "Use Multi-Level BOM" checkbox) fails, because `below` only looks under the anchor's own width.
- Each manufacturing run adds a new BOM for E2E-SEED-003 (it becomes the default), consumes one E2E-SEED-001 and one E2E-SEED-002, and puts one E2E-SEED-003 into "Finished Goods - ETC". BOM rates follow the moving valuation, so the test does not check costs.
- `click on table at row "1" and column "Account"` clicks the module rail instead of the Journal Entry grid: testRigor treats the rail as a table and "Account" matches its "Accounts" button. The journal entry test uses the form's "Quick Entry" dialog (Amount, Debit Account, Credit Account), which saves a Draft with both grid rows filled. Trade-off: the grid itself is not typed into.
- In the Quick Entry dialog, Tab out of a link field leaves the next field's dropdown open over the fields below, and the next `enter` lands in the wrong input ("Cash - ETC" went into Remark). Leave each field by clicking the dialog title (`click "Quick Journal Entry"`); a Tab out of Credit Account would also open the Date picker, and Escape would close the whole dialog.
- A submitted Journal Entry shows its entry type ("Journal Entry") in the title badge, not a status; the test checks the activity line "You submitted this document".
- The transfer test moves 2 units of E2E-SEED-002 from Stores to Work In Progress per run (Stores was 93 on 2026-10-20); reinstall the site when it runs low.
- After submitting a Payment Entry created from an invoice, `go back` returns to the invoice, which already shows the new status (Paid) without a reload.
