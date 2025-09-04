
use role consumer_role;
-- Note: If you have an actual application, replace falkordb_app with the correct application name
-- drop application if exists your_app_name;
drop warehouse if exists wh_consumer;

--Step 2 - Clean Up Compute Pool (as admin)
use role accountadmin;
drop compute pool if exists pool_consumer_containers;

--Step 3 - Clean Up Provider Objects
use role falkordb_role;
drop application package if exists falkordb_app_pkg;
-- Drop database objects in correct order
use database falkordb_app;
drop image repository if exists falkordb_app.napp.img_repo;
drop stage if exists falkordb_app.napp.app_stage;
drop schema if exists falkordb_app.napp;
drop database if exists falkordb_app;
drop warehouse if exists wh_falkordb;

--Step 4 - Clean Up Roles (as admin)
use role accountadmin;
drop role if exists falkordb_role;
drop role if exists consumer_role;