/*===========================================================
STRATAVAX REAL ESTATE
DYNAMIC PROPERTY PRICING & MARKET INTELLIGENCE SYSTEM
===========================================================

Business objective

This script evaluates property valuations, market dynamics, and
pricing performance so Stratavax can make data driven pricing,
investment, and revenue decisions.

The goal is to identify pricing opportunities, track market
movements, and check whether properties are priced competitively
against current market conditions.

Business context

Stratavax operates across several real estate markets, with
properties that differ in location, size, and transaction type.
Management needs ongoing visibility into:

1. Whether property pricing is competitive.
2. Market demand trends across cities.
3. How transaction prices compare with listing prices.
4. Pricing opportunities across the portfolio.
5. Market conditions influencing property values.
6. Where to focus future pricing and investment decisions.

Key questions this script answers

1. Are our properties priced competitively?
2. Which properties are potentially underpriced or overpriced?
3. How do transaction prices compare with listing prices?
4. How does market demand influence pricing trends?
5. What impact do interest rates have on property values?
6. Which markets show stronger pricing performance?
7. How are property values changing over time?
8. What pricing actions should management prioritize?

Analysis flow: Data validation -> Market data model -> Pricing
evaluation -> Demand and rate assessment -> Trend analysis ->
Pricing recommendations.

===========================================================*/

/*-----------------------------------------------------------
STEP 1: DATA QUALITY VALIDATION

Before building any KPI, we check the basic health of the data:
row counts, a quick look at the transactions table, and whether
the join keys we are about to rely on actually line up. This
step is what caught the join problem described further down, so
it stays in the script rather than being a throwaway check.
-----------------------------------------------------------*/

SELECT COUNT(*) AS property_count
FROM properties;

SELECT TOP 10 *
FROM transactions;

-- Confirm market_data has at most one row per city per day.
-- If this returns any rows, the pricing join below would start
-- duplicating property records again, so it is worth re-running
-- whenever the source data refreshes.
SELECT location, date, COUNT(*) AS row_count
FROM market_data
GROUP BY location, date
HAVING COUNT(*) > 1;

-- Confirm every city in properties actually has market coverage.
-- Cities that fall through here will show NULL market benchmarks
-- in the views below, which is expected but worth knowing about.
SELECT DISTINCT p.city
FROM properties p
WHERE NOT EXISTS (
    SELECT 1 FROM market_data m WHERE m.location = p.city
);

/*-----------------------------------------------------------
STEP 2: BUILD THE PROPERTY PRICING MODEL

This is the view every property level pricing KPI runs from.

A note on a bug found and fixed here: the first version of this
view joined every property straight to market_data on city alone.
market_data is a daily time series (one row per city per day
going back to 2018), so joining on city with no date attached
matched each property to every single day of market history for
its city, not just one relevant snapshot. For a city with roughly
2,500 days of history, that meant one property could turn into
2,500 duplicate rows. It did not just bloat the row count: KPI 5
and KPI 6 (demand and interest rate impact) group by demand_index
and interest_rate, and with this join, a single transaction got
spread across every demand and interest rate value ever recorded
for its city, on random unrelated days. Any real relationship
between demand, rates, and price got buried in noise.

The fix is to give the join a date to match on. Properties have
a listing_date, so we match each property to the market
conditions on the day it was actually listed. That gives one
market row per property, which is both correct and more useful,
since it tells us what the market looked like at the moment the
price was set, not some average across six years.
-----------------------------------------------------------*/

CREATE VIEW v_property_pricing AS
SELECT
    p.property_id,
    p.property_type,
    p.city,
    p.country,
    p.price AS listing_price,
    p.size_sqft,
    p.bedrooms,
    p.status,
    p.listing_date,
    m.avg_price_per_sqft,
    m.demand_index,
    m.interest_rate
FROM properties p
LEFT JOIN market_data m
    ON p.city = m.location
    AND p.listing_date = m.date;

/*-----------------------------------------------------------
STEP 3: BUILD THE TRANSACTION PRICING MODEL

A separate view for anything that involves an actual sale or
rental transaction. Keeping this apart from v_property_pricing
matters for the same reason described above: a property can have
several transactions over time, so joining transactions into the
same view as market_data would reintroduce a similar row
multiplication problem. Here, market conditions are matched to
the transaction_date rather than the listing_date, since we want
to know what demand and rates looked like on the day the deal
actually closed.
-----------------------------------------------------------*/

CREATE VIEW v_property_transactions AS
SELECT
    p.property_id,
    p.city,
    p.price AS listing_price,
    t.transaction_id,
    t.transaction_type,
    t.amount AS transaction_price,
    t.transaction_date,
    m.avg_price_per_sqft,
    m.demand_index,
    m.interest_rate
FROM properties p
JOIN transactions t
    ON p.property_id = t.property_id
LEFT JOIN market_data m
    ON p.city = m.location
    AND t.transaction_date = m.date;

/*-----------------------------------------------------------
KPI 1: PROPERTY VALUE PER SQUARE FOOT

The price assigned to each square foot of space. This is the
common yardstick used everywhere else in the script to compare
properties of different sizes on equal footing.
-----------------------------------------------------------*/

SELECT
    property_id,
    price / NULLIF(size_sqft, 0) AS price_per_sqft
FROM properties;

/*-----------------------------------------------------------
KPI 2: MARKET PRICING GAP ANALYSIS

Compares each property's price per square foot against the
market benchmark for its city on its listing date.

A positive gap means the property is priced above what the
market was doing that day. A negative gap points to a possible
pricing opportunity.
-----------------------------------------------------------*/

SELECT
    property_id,
    listing_price,
    size_sqft,
    avg_price_per_sqft,
    (listing_price / NULLIF(size_sqft, 0)) - avg_price_per_sqft AS price_gap
FROM v_property_pricing;

/*-----------------------------------------------------------
KPI 3: UNDERVALUED PROPERTY IDENTIFICATION

Flags properties listed below the market benchmark for their
city and listing date. These are the properties most worth a
second look for a price increase.
-----------------------------------------------------------*/

SELECT
    property_id,
    city,
    listing_price,
    size_sqft
FROM v_property_pricing
WHERE (listing_price / NULLIF(size_sqft, 0)) < avg_price_per_sqft;

/*-----------------------------------------------------------
KPI 4: LISTING PRICE PERFORMANCE ANALYSIS

Compares each property's listing price against what it actually
sold or rented for, using the transaction level view so a
property with several transactions is averaged correctly and
without inflating the market join.
-----------------------------------------------------------*/

SELECT
    property_id,
    listing_price,
    AVG(transaction_price) AS avg_sale_price
FROM v_property_transactions
GROUP BY property_id, listing_price;

/*-----------------------------------------------------------
KPI 5: MARKET DEMAND ANALYSIS

Groups actual transactions by the demand_index recorded on the
day they closed, and checks how transaction prices move as
demand rises or falls. Because v_property_transactions matches
market data to the transaction date, this reflects a real
day-of-sale relationship rather than a randomly shuffled one.
-----------------------------------------------------------*/

SELECT
    demand_index,
    AVG(transaction_price) AS avg_price
FROM v_property_transactions
GROUP BY demand_index
ORDER BY demand_index;

/*-----------------------------------------------------------
KPI 6: INTEREST RATE IMPACT ANALYSIS

Same idea as KPI 5, using interest_rate on the transaction date
to see how borrowing costs line up with transaction prices.
-----------------------------------------------------------*/

SELECT
    interest_rate,
    AVG(transaction_price) AS avg_price
FROM v_property_transactions
GROUP BY interest_rate
ORDER BY interest_rate;

/*-----------------------------------------------------------
KPI 7: PROPERTY VALUE TREND ANALYSIS

Tracks historical valuations year over year to spot long term
pricing trends across the portfolio. This table is independent
of the joins above, so it carries no risk of duplication.
-----------------------------------------------------------*/

SELECT
    YEAR(date) AS year,
    AVG(valuation_price) AS avg_price
FROM valuation_history
GROUP BY YEAR(date)
ORDER BY year;

/*-----------------------------------------------------------
KPI 8: CITY LEVEL MARKET PERFORMANCE

Average listing price and average size by city, to see which
markets are performing best and where expansion or investment
might make sense.
-----------------------------------------------------------*/

SELECT
    city,
    AVG(price) AS avg_listing_price,
    AVG(size_sqft) AS avg_size
FROM properties
GROUP BY city
ORDER BY avg_listing_price DESC;

/*-----------------------------------------------------------
KPI 9: DYNAMIC PRICING DECISION ENGINE

Turns the pricing gap from KPI 2 into a plain recommendation
for each property.

Reduce Price   : listed above the market rate for its city and
                 listing date.
Increase Price : listed below the market rate.
Optimal        : in line with the market.
-----------------------------------------------------------*/

SELECT
    property_id,
    listing_price,
    size_sqft,
    avg_price_per_sqft,
    CASE
        WHEN (listing_price / NULLIF(size_sqft, 0)) > avg_price_per_sqft
            THEN 'Reduce Price'
        WHEN (listing_price / NULLIF(size_sqft, 0)) < avg_price_per_sqft
            THEN 'Increase Price'
        ELSE 'Optimal'
    END AS pricing_action
FROM v_property_pricing;

/*===========================================================

BUSINESS IMPACT

This framework helps leadership:

1. Improve pricing accuracy across the property portfolio.
2. Catch undervalued and overpriced properties early.
3. Track changing market conditions on an ongoing basis.
4. Set pricing strategy using real market intelligence rather
   than guesswork.
5. Make better investment and acquisition decisions.
6. Identify the strongest performing markets.
7. Find revenue opportunities across the portfolio.
8. Build a pricing process backed by data rather than instinct.

===========================================================*/
