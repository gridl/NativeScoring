/*
######################################################
Author: Tomaz Kastrun
Blog Post: Native scoring in SQL Server 2017 using R
Blog URL: tomaztsql.wordpress.com
Date: 28.05.2018
#####################################################
*/

USE [master];
GO

CREATE DATABASE rxNativeScoring;
GO

USE rxNativeScoring;
GO

DROP TABLE IF EXISTS ArrivalDelay;
GO

CREATE TABLE ArrivalDelay
(
"ArrDelay" VARCHAR(10)
,"CRSDepTime" VARCHAR(20)
,"DayOfWeek" VARCHAR(20)
)


BULK INSERT ArrivalDelay
 FROM 'C:\Program Files\Microsoft SQL Server\140\R_SERVER\library\RevoScaleR\SampleData\AirlineDemoSmall.csv'
   WITH   
      (  FIELDTERMINATOR =',',  ROWTERMINATOR = '0x0a', FIRSTROW =  2, CODEPAGE = 'RAW');  


SELECT
CAST(arrdelay as INT) As ArrDelay
,CAST(CRSDepTime AS FLOAT) AS CRSDepTime
,CASE 
		WHEN [DayOfWeek] like '%Monday%' THEN 1
		WHEN [DayOfWeek] like '%Tuesday%' THEN 2
		WHEN [DayOfWeek] like '%Wednesday%' THEN 3
		WHEN [DayOfWeek] like '%Thursday%' THEN 4
		WHEN [DayOfWeek] like '%Friday%' THEN 5
		WHEN [DayOfWeek] like '%Saturday%' THEN 6
		WHEN [DayOfWeek] like '%Sunday%' THEN 7 END AS [DayOfWeek]
INTO ArrDelay
 FROM arrivalDelay
 WHERE
	ISNUMERIC(arrdelay) = 1
-- (582628 rows affected)
-- Duration 00:00:01

DROP TABLE IF EXISTS arrivalDelay;
GO


SELECT TOP 20000 *
INTO ArrDelay_Train
FROM ArrDelay ORDER BY NEWID()
-- (20000 rows affected)


SELECT  *
INTO ArrDelay_Test
FROM ArrDelay  AS AR
WHERE NOT EXISTS (SELECT * FROM ArrDelay_Train as ATR
					WHERE
						ATR.arrDelay = AR.arrDelay
					AND ATR.[DayOfWeek] = AR.[DayOfWeek]
					AND ATR.CRSDepTime = AR.CRSDepTime
					)
-- (473567 rows affected)


DROP TABLE IF EXISTS arrModels;
GO

CREATE TABLE arrModels (
	model_name VARCHAR(100) NOT NULL PRIMARY KEY
   ,native_model VARBINARY(MAX) NOT NULL);
GO


-- regular model creation
DECLARE @model VARBINARY(MAX);
EXECUTE sp_execute_external_script
   @language = N'R'
  ,@script = N'
    arrDelay.LM <- rxLinMod(ArrDelay ~ DayOfWeek + CRSDepTime, data = InputDataSet)
    model <- rxSerializeModel(arrDelay.LM)'
  ,@input_data_1 = N'SELECT * FROM ArrDelay_Train'
  ,@params = N'@model varbinary(max) OUTPUT'
  ,@model = @model OUTPUT
  INSERT [dbo].arrModels([model_name], [native_model])
  VALUES('arrDelay.LM.V1', @model) ;
-- (1 row affected)
-- Duration 00:00:22



-- Model for Native scoring
DECLARE @model VARBINARY(MAX);

EXECUTE sp_execute_external_script
   @language = N'R'
  ,@script = N'
    arrDelay.LM <- rxLinMod(ArrDelay ~ DayOfWeek + CRSDepTime, data = InputDataSet)
    model <- rxSerializeModel(arrDelay.LM, realtimeScoringOnly = TRUE)'
  ,@input_data_1 = N'SELECT * FROM ArrDelay_Train'
  ,@params = N'@model varbinary(max) OUTPUT'
  ,@model = @model OUTPUT
  INSERT [dbo].arrModels([model_name], [native_model])
  VALUES('arrDelay.LM.NativeScoring.V1', @model) ;
-- (1 row affected)
-- Duration 00:00:22


 SELECT 
  *
  ,DATALENGTH(native_model)/1024. AS [model_size (kb)]
FROM arrModels;




/*
--------------------------
-- SCORING
--------------------------
*/


-- Using sp_execute_external_script
DECLARE @model VARBINARY(MAX) = (SELECT native_model FROM arrModels WHERE model_name = 'arrDelay.LM.V1')

EXEC sp_execute_external_script
    @language = N'R'
   ,@script = N'
				modelLM <- rxUnserializeModel(model)
				OutputDataSet <- rxPredict( model=modelLM,
											  data = ArrDelay_Test,
											  #type = "response",
											  type = "link",
											  predVarNames = "ArrDelay_Pred",s
											  extraVarsToWrite = c("ArrDelay","CRSDepTime","DayOfWeek")
											  )'
    ,@input_data_1 = N'SELECT * FROM dbo.ArrDelay_Test'
    ,@input_data_1_name = N'ArrDelay_Test'
    ,@params = N'@model VARBINARY(MAX)'
    ,@model = @model
WITH RESULT SETS
((
 AddDelay_Pred FLOAT
,ArrDelay INT 
,CRSDepTime NUMERIC(16,5)
,[DayOfWeek] INT
))
-- (473567 rows affected)
-- Duration 00:00:08


-- Using Real Time Scoring
DECLARE @model varbinary(max) = ( SELECT native_model FROM arrModels WHERE model_name = 'arrDelay.LM.NativeScoring.V1');

SELECT 
  NewData.*
 ,p.*
  FROM PREDICT(MODEL = @model, DATA = dbo.ArrDelay_Test as newData)
  WITH(ArrDelay_Pred FLOAT) as p;
GO
-- (473567 rows affected)
-- Duration 00:00:04






--- TEST of using native scoring without R installed 
-- (I will simulate this .. as if SQl Server Launchpad will be turned off)

-- I will stop the service
SELECT * FROM sys.dm_server_services

-- I can easly rerun the PREDICT function, whereas the sp_execute_External_script will fail



-- cleaning up
USE [master];
GO

DROP DATABASE rxNativeScoring;
GO