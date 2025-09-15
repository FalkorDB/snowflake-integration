# This app simulate

1. User (consumer) of snowflake that has 3 tables with data taken from consumer/src
2. falkordb app published into snowflake marketpalce with staging folder that can accept data from consumer
3. Consumer deploy instance of falkordb app and setup his staging
4. Consumer call falkordb app procedure load_csv(graph, table, chypher_query) that
   1. load the data from table to the staging earia with the name table.csv
   2. call the service function  load_csv(graph, table.csv, chyper_query) keep the result, delete table.csv from the staging and return the result to the caller

There should be only 3 scripts for setup and 3 scripts for teardown

1. setup_consumer.sh
2. setup_app.sh
3. instansiate_app.sh

and for teardown

1. teardown_consumer.sh
2. teardown_app.sh
3. uninstansiate_app.sh
