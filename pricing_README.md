# Stratavax Property Pricing & Market Intelligence

A SQL analysis project that checks whether a real estate portfolio is priced right against the market, and flags exactly which properties to raise, lower, or leave alone.

## Business problem

Stratavax is a real estate company holding properties across eight cities: Lagos, Dubai, Sydney, Toronto, Singapore, London, Berlin, and New York. Like most portfolio owners, they set listing prices up front and then mostly leave them alone. The problem with that approach is that markets move. A price that made sense in 2020 might be well off the mark by 2023, and nobody in the business had an easy way to check.

Management needed a way to answer a few plain questions. Are we priced competitively right now? Which properties are quietly underpriced, and which ones are sitting overpriced and probably why they're not moving? Does demand or the interest rate environment actually show up in what properties sell for? And which markets are worth pushing into further?

This project builds that check directly into SQL, so pricing decisions can be based on what the market is actually doing instead of a gut feeling or a stale comp sheet.

## Data source

The analysis runs on four tables from Stratavax's internal systems, provided as CSV extracts:

**properties** holds the core portfolio: property ID, type, city, country, price, size, bedrooms, status, and listing date, for roughly 3,000 properties.

**transactions** records actual sales and rentals: transaction ID, property ID, customer ID, transaction type, date, amount, and payment method.

**market_data** is a daily time series per city going back to 2018, covering average price per square foot, a demand index, and the prevailing interest rate.

**valuation_history** tracks periodic valuations per property over time, used for the long-term trend view.

A couple of honest caveats about this data. The properties table has both a `location` and a `city` field, and both are populated with the same pool of city names but don't always agree with each other on the same row. This script uses `city` as the field that ties a property to its market, since that's what lines up with `market_data.location`, but if you're working from the real source system, it's worth confirming with whoever owns that table which field is actually meant to be authoritative. Two other tables came with this dataset, customer records and agent records, but neither was needed for a pricing analysis, so they're not part of this project.

## Methodology

The approach follows a standard analytics sequence: validate the data first, build a clean model to query against, then layer KPIs on top of that model.

Step one is a data quality pass. Before trusting any join, I checked whether `market_data` had more than one row per city per day (it shouldn't, and it didn't) and whether every city in the properties table actually had matching market coverage. Both checks are left in the script rather than run once and thrown away, since they're cheap to run and catch problems early if the source data changes.

Step two builds two views instead of one. `v_property_pricing` connects each property to the market conditions on the day it was listed, giving a clean, one-row-per-property pricing model. `v_property_transactions` connects each actual sale or rental to the market conditions on the day it closed. Splitting these into two views instead of one was a deliberate fix; more on why in the next section.

From there, nine KPIs build on top of those two views: price per square foot, pricing gap against the market, a list of underpriced properties, listing price versus actual sale price, how demand and interest rates relate to transaction prices, a multi-year valuation trend, city-level performance, and finally a plain-language pricing recommendation for every property in the portfolio.

## Analysis & error check

Going through the original script surfaced one real bug worth calling out.

The original version joined every property straight to `market_data` using only the city, with no date attached. The catch is that `market_data` is a daily series with roughly 2,500 rows per city stretching back to 2018. Joining on city alone matched each property to every single day of market history for its city, not just the one day that mattered. A single property could turn into thousands of duplicate rows.

That's not just a bloat problem, it actively broke two of the KPIs. The demand and interest rate analyses (KPI 5 and KPI 6) work by grouping transactions according to the demand or rate value recorded at the time. With the old join, a single real transaction got paired with every demand and interest rate value ever recorded for its city, on random days that had nothing to do with when the deal actually happened. Whatever real relationship existed between demand, rates, and price got buried under thousands of irrelevant pairings.

The fix was to give the join something to match on besides city. Properties already have a `listing_date`, so the pricing view now matches each property to the market snapshot from the day it was listed. Transactions have their own `transaction_date`, so the transaction view matches on that instead. Each property or transaction now gets exactly one relevant market row, and the demand and rate analyses reflect an actual same-day relationship rather than noise. I also split the property-level view and the transaction-level view apart, since combining them again would reintroduce a similar duplication problem (a property with several transactions joined to several market rows multiplies just as badly).

Everything else in the script checked out. The pricing gap logic, the undervalued property filter, and the CASE-based pricing recommendation all use straightforward, correct math once they're pulling from the corrected views.

## Insight

Running the corrected KPIs against this portfolio shows a fairly wide pricing gap: a meaningful share of properties are listed noticeably above or below what the market was doing on their listing date, rather than clustered tightly around it. That spread is exactly what you'd expect from a portfolio where prices were set once and never revisited, and it's the clearest sign that a periodic pricing review would pay for itself.

The city-level view also shows real separation in performance. Some cities carry both higher average prices and larger average unit sizes, which points to where the stronger demand actually sits, rather than assuming every market in the portfolio behaves the same way.

Once the demand and interest rate join was fixed to match by actual transaction date, a genuine pattern emerges between market conditions and transaction prices instead of the flat, noisy relationship the buggy version would have shown.

## Recommendation

Put the pricing gap and dynamic pricing KPIs on a recurring cycle, monthly is reasonable, rather than treating this as a one-off report. Properties flagged "Reduce Price" for several cycles in a row are worth a hard look at whether they're overpriced or just sitting in a slower part of the portfolio. Properties flagged "Increase Price" are the more urgent case, since Stratavax is very likely leaving money on the table every day that price stays where it is.

Use the city-level KPI to guide where new listings or acquisitions get prioritized, rather than spreading effort evenly across all eight markets.

## Business impact

A structured pricing review catches revenue leakage that a static pricing model never will. Every day an underpriced property sits on the market at the wrong number is money left behind, and every overpriced property sitting unsold is a property tying up capital that could be working elsewhere. Even a modest correction across a 3,000-property portfolio adds up to a real number, and it comes from better use of data the company already had, not from any new spend.

## What was done

Reviewed the business objective and the four source tables, then rebuilt the pricing data model from the ground up to fix a join that was silently duplicating rows and distorting the demand and interest rate KPIs. Added data validation checks at the top of the script so the same class of problem gets caught automatically if the underlying data changes. Rebuilt all nine KPIs on the corrected model and confirmed the logic in each one, including the pricing gap calculation and the final CASE-based pricing recommendation.

## Tools used and how they helped

SQL views were used to separate the property-level pricing model from the transaction-level model, which is what made it possible to fix the duplication bug without rewriting every KPI from scratch. `NULLIF` guards against division by zero wherever price is divided by size or by another price, which matters given a live portfolio will always have a few properties with missing or zero size data. `CASE` expressions turn the pricing gap into a plain recommendation any non-technical stakeholder can read directly, without needing to interpret a raw number. `GROUP BY` and `HAVING` drive the aggregation KPIs, and window-style date functions (`YEAR()`) support the multi-year valuation trend.

## Results

A working, corrected SQL pipeline that takes raw property, transaction, and market data and turns it into nine decision-ready KPIs, plus a documented data quality fix that changes the actual conclusions of two of those KPIs. The end output for every property in the portfolio is a plain recommendation: reduce price, increase price, or hold at the current level, backed by an accurate, date-matched comparison against real market conditions rather than a citywide average with no time dimension attached to it.
