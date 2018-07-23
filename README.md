# Steam Gems "Arbitrage" bot, PoC

# Why
Some steam items(backgrounds, smiles, and some others) can be converted to gems. Gems can be packed into a sack of gems.
Sacks can be sold at community market.

Very often you can make profit from buying some stuff, converting it to gems, and sell back.

This script shows you a lot that you need to buy to make profit.

# How
Bot scans the whole community market and checks prices with the corresponding values in gems.

To speed things up, bot first checks the prices in USD(it's default currency in Steam, called 'base' check in code).

If profit is possible, bot digs deeper and checks available lots for this item in another currency with minimal fraction < $0.01, which is better for bigger revenues(RUR is used).

If revenue is bigger than configured threshold, then lot's url is printed.

# Tech info
Steam enforces evil per-IP limits for their market API. To overcome it we use multiple proxies - AWS Lambda functions, as they provide different IPs for almost every instance.

Code is fully asynchronous.
Local redis is used as hot cache, and DynamoDB as persistent storage.

Approximate scan time for 250 workers with default settings is 1000 seconds. In case of first run or run after few days since last run, time will be inreased, as bot needs to fetch steam values to items (they are changing over time!)

# Run
```
$ perl scan_market.pl
```
