-- Copyright 2008 Maurice Pelchat  
-- Projet YourSQLDba : Auto-maintenance tools for SQL Server Databases
-- Sponsor : Société GRICS
-- Author : Maurice Pelchat, Société GRICS
If Db_name() <> 'Master'  Use master;
GO
if OBJECT_ID('tempdb..#version') is not null drop table #Version
create table #Version (version nvarchar(40), VersionDate datetime)
set nocount on
insert into #Version Values ('6.5.6.1', convert(datetime, '2017-03-01', 120))
--=================================================================================================================
-- 
--=================================================================================================================

SET QUOTED_IDENTIFIER ON 
SET ANSI_NULLS ON
GO
If SCHEMA_ID ('f$') IS NULL Exec ('Create Schema f$ authorization dbo')
GO
----------------------------------------------------------------------------------------------------------------
-- Cleanup LibraryObjects if some support objects are there
----------------------------------------------------------------------------------------------------------------
If Object_id('f$.GenDropObj') IS NOT NULL
Begin
  Set nocount on
  if OBJECT_ID('tempdb..#ToDrop') is not null Drop table #ToDrop
  ;With 
    ObjectsToDrop as 
    (
    Select OBJECT_SCHEMA_NAME(Object_id)+'.'+Obj.Name as ObjName
    From sys.objects Obj
    Where Obj.is_ms_shipped = 0 
      And Object_Schema_name (Obj.object_id) = 'f$' 
      And 'f$.' + Name NOT IN ('f$.ObjectInfo', 'f$.GenDropObj', 'f$.DropObj', 'f$.CleanupLibraryObjects', 'f$.DropTempTb')
      And (   Obj.type IN ('FN', 'TF', 'IF', 'P', 'SN', 'V') -- fonction procedures synonymes vues, mais conserve les tables
           Or (Obj.type_desc = 'User_Table' And Name Like 'ErrorLogStack[0-9]%[0-9]')
           Or (Obj.type_desc = 'User_Table' And Name Like 'RealScriptToRun')
          )
      And (
             Object_definition(obj.object_id) Like '%--f$SignatureForCleanup%'
          Or Obj.type_desc = 'User_Table'
          ) 
    )
  Select ToDrop.Stmt, ROW_NUMBER() Over (Order By ToDrop.FqqDbName) as Seq 
  Into #ToDrop
  From 
    ObjectsToDrop as Obj
    cross apply f$.GenDropObj (Obj.ObjName, 1) as ToDrop

  Create Index iToDrop On #ToDrop (seq)
  Declare @Seq Int = 0
  Declare @Sql Nvarchar(max)
  While (1=1)
  Begin
    Select top 1 @Seq=Seq, @Sql=Stmt From #ToDrop Where seq > @Seq
    If @@ROWCOUNT = 0 Break;
    --print @sql
    Exec (@Sql)
  End

  Exec ('If Object_Id(''f$.ObjectInfo'') IS NOT NULL Drop Function f$.ObjectInfo')
  Exec ('If Object_Id(''f$.GenDropObj'') IS NOT NULL Drop Function f$.GenDropObj')
  Exec ('If Object_Id(''f$.DropObj'') IS NOT NULL Drop Proc f$.DropObj')
  Exec ('If Object_Id(''f$.DropTempTb'') IS NOT NULL Drop Proc f$.DropTempTb')
  Exec ('If Object_Id(''f$.CleanupLibraryObjects'') IS NOT NULL Drop Proc f$.CleanupLibraryObjects')
End
GO
If object_id('f$.DropTempTb') IS NOT NULL drop Procedure f$.DropTempTb
GO
--f$SignatureForCleanup
Create Procedure f$.DropTempTb @tb sysname
as If Object_id('TempDb..'+@tb) IS NOT NULL Exec ('Drop Table '+@tb)
GO
-------------------------------------------------------------------------------------------------------------
-- If a schema need to be remove, this proc allow to do a full cleanup of this schema
-- by default this is the f$ scheam, and it is useful if it get messy, because some objects
-- where not created using the f$SignatureForCleanup
-- This proc has no dependency on other internat proc, but must be exists and run in the context 
-- database that contains the schema, and it must remain that way.
-------------------------------------------------------------------------------------------------------------
If object_id('f$.CleanupSchema') is not null 
  drop Procedure f$.CleanupSchema 
GO
--f$SignatureForCleanup
Create Procedure f$.CleanupSchema @Sch sysname = 'f$'
as
Begin
  Set Nocount On

  if OBJECT_ID('tempdb..#ToDrop') is not null Drop table #ToDrop
  ;With 
    TypeToDropObj as
    (
    Select *
    From 
      (
      Values -- les objets que cette librairie supporte
        ('FN', 'Function') 
      , ('TF', 'Function')
      , ('IF', 'Function')
      , ('P',  'Procedure')
      , ('SN', 'Synonym')
      , ('V',  'View') 
      , ('U',  'Table') 
      , ('AF', 'Function') -- CLR Aggregate function 
      , ('FT', 'Function') -- CLR Table Function 
      , ('FS', 'Function') -- CLR Scalar Function 
      , ('PC', 'Procedure') -- CLR Procedure
      ) as T (type, typeForDrop)
    )
  , ObjectsToDrop as 
    (
    Select QuoteName(OBJECT_SCHEMA_NAME(Object_id))+'.'+QuoteName(Obj.Name) as ObjName, type
    From 
      sys.objects as Obj
    Where Obj.is_ms_shipped = 0 
      And Object_Schema_name (Obj.object_id) = @Sch  
      And type IN (Select type From TypeToDropObj) 
    )
  , GenDropObj as 
    (
    Select 'Drop '+tObj.typeForDrop+ ' ' + Obj.ObjName as Stmt, ObjName
    From 
      ObjectsToDrop Obj
      JOIN 
      TypeToDropObj tObj ON tObj.type = Obj.Type
    )
  Select Stmt, ROW_NUMBER() Over (Order By ObjName) as Seq 
  Into #ToDrop
  From 
    GenDropObj as Obj

  Create Index iToDrop On #ToDrop (seq)
    Declare @Seq Int = 0
  Declare @Sql Nvarchar(max)
  While (1=1)
  Begin
    Select top 1 @Seq=Seq, @Sql=Stmt From #ToDrop Where seq > @Seq
    If @@ROWCOUNT = 0 Break;
    print @sql
    Exec (@Sql)
  End

  If Schema_id(@Sch) IS NOT NULL Exec ('Drop Schema '+@Sch)
End
Go

----------------------------------------------------------«---------------------------------------------------
-- This procedure makes SQL instruction to drop an object.  It finds its type and make it.
-- Actually it can't gen object type info on objets external to the database because it queries sys.Objects
-- 
-------------------------------------------------------------------------------------------------------------
If object_id('f$.ObjectInfo ') is not null 
  drop function f$.ObjectInfo
GO
--f$SignatureForCleanup
create Function f$.ObjectInfo (@name sysname)
Returns Table 
as
Return
(
With 
  Prm as (select @Name as NamePrm)
  --Prm as ( Select 'realscriptorun' as NamePrm)
, NameParsing as 
  (
  Select 
    '#db#.#sh#.#n#' as FullDbQualifiedAndQuotedObjNameTemplate
  , '#sh#.#n#' as FullQualifiedAndQuotedObjNameTemplate
  , QuoteName(isnull(PARSENAME (namePrm, 3),db_name())) as db
  , QuoteName(isnull(PARSENAME (namePrm, 2), 'f$')) as sh
  , QuoteName(isnull(PARSENAME (namePrm, 1), '')) as n
  , *
  From Prm
  )
  --select * from NameParsing
, FullQualifiedAndQuotedObjName as 
  (
  select T1.FqqDbName, T2.FqqName, NP.*
  From 
    NameParsing as NP
    Cross Apply (Select NP.db+'.'+NP.sh+'.'+NP.n) as T1(FqqDbName)
    Cross Apply (Select NP.sh+'.'+NP.n) as T2(FqqName)
  )
  --Select * From FullQualifiedAndQuotedObjName
, ExistingObjectAndType as 
  (
  Select 
    Case 
      When objectpropertyEx(OBJECT_ID(FqqDbName), 'IsProcedure')=1 Then 'Procedure'
      When objectpropertyEx(OBJECT_ID(FqqDbName), 'IsTrigger')=1 Then 'Trigger'
      When objectpropertyEx(OBJECT_ID(FqqDbName), 'IsInlineFunction')=1 Then 'Function'
      When objectpropertyEx(OBJECT_ID(FqqDbName), 'IsScalarFunction')=1 Then 'Function'
      When objectpropertyEx(OBJECT_ID(FqqDbName), 'IsTableFunction')=1 Then 'Function'
      When objectpropertyEx(OBJECT_ID(FqqDbName), 'IsUserTable')=1 Then 'Table'
      When objectpropertyEx(OBJECT_ID(FqqDbName), 'IsView')=1 Then 'View'
      -- With SQL2008R2 SP1 objectpropertyEx fails to detect CLR FUNCTION with the is???Function above
      When exists(Select * from sys.objects where object_id = OBJECT_ID(FqqDbName) And type_desc Like '%FUNCTION') Then 'Function'
      When exists(Select * from sys.objects where object_id = OBJECT_ID(FqqDbName) And type_desc Like 'SYNONYM') Then 'Synonym'  
      -- no property for Sequence objects
      When exists(Select * from sys.objects where object_id = OBJECT_ID(FqqDbName) And type_desc Like 'SEQUENCE_OBJECT') Then 'SEQUENCE'  
      Else ''
    End as ObjType
  , *
  From 
    FullQualifiedAndQuotedObjName
  Where OBJECT_ID(FqqDbName) is Not NULL
  )
Select E.FqqDbName, E.FqqName, E.ObjType, E.Db, E.Sh, E.n
From ExistingObjectAndType  E
)
GO
--Select * from f$.ObjectInfo('[f$].[realscripttorun]')
--Select * from f$.ObjectInfo('f$.realscripttorun')
--Select * from f$.ObjectInfo('f$.FP4TSQLVersionInfo')
--Select O.*
--From 
--  sys.objects
--  cross apply f$.ObjectInfo(f$.FullObjName(object_id)) as O

-------------------------------------------------------------------------------------------------------------
-- This procedure makes SQL instruction to drop an object.  It finds its type and make it.
-- It can drop object from other databases and display drop statement.
-------------------------------------------------------------------------------------------------------------
If object_id('f$.GenDropObj ') is not null 
  drop function f$.GenDropObj
GO
--f$SignatureForCleanup
create Function f$.GenDropObj (@name sysname, @Silent int = 0)
Returns Table 
as
Return
(
With 
  Prm as 
  (
  --select 'f$.ScriptToRun' as NamePrm, 0 as Silent, 1 as SingleBatch  -- to test
  select @Name as NamePrm, @silent as Silent Where @Name IS NOT NULL
  )
  --Select * from Prm
, DropStatementBuildElements as 
  (
  Select 
    Case Prm.Silent When 0 Then ' Print ''use #db#; Drop #ObjType# #FqqDbName#''; ' Else '' End 
  + Case 
      When ObjType = '' collate database_default
      Then 'Raiserror (N''Unsupported object type for f$.DropObj #FqqDbName#'', 11, 1)'
      Else 'Exec (''use #db#; Drop #ObjType# #Sh#.#n#'')'  
    End as DropStatementOrWarning
  , Obj.*
  From 
    Prm
    Cross Apply f$.ObjectInfo(Prm.NamePrm) Obj
  )
  --Select * From DropStatementBuildElements
, BuildStatement as
  (
  Select r7.s as stmt, D.*
  From 
     DropStatementBuildElements D
     CROSS APPLY (Select REPLACE(D.DropStatementOrWarning, '#Sh#', D.Sh)) r1(s)
     CROSS APPLY (Select REPLACE(r1.s, '#n#', D.n)) r2(s)
     CROSS APPLY (Select REPLACE(r2.s, '#sh#', D.sh)) r3(s)
     CROSS APPLY (Select REPLACE(r3.s, '#FqqName#', D.FqqName)) r4(s)
     CROSS APPLY (Select REPLACE(r4.s, '#FqqDbName#', D.FqqDbName)) r5(s)
     CROSS APPLY (Select REPLACE(r5.s, '#Db#', D.db)) r6(s)
     CROSS APPLY (Select REPLACE(r6.s, '#ObjType#', D.ObjType)) r7(s)
  )
Select *
From 
  BuildStatement S
-- Select * From f$.GenDropObj('[f$].[realscripttorun]', 0)
--Select O.*
--From 
--  sys.objects
--  cross apply f$.ObjectInfo(f$.FullObjName(object_id)) as O
) -- f$.GenDropObj 
GO
If object_id('f$.DropObj') is not null 
  drop procedure f$.DropObj
GO
create Procedure f$.DropObj @name sysname, @Silent int = 0
as
Begin
  Set Nocount On

  -- there is a single objet, so make a single batch
  Declare @Sql Nvarchar(max)
  Select @Sql = ToDrop.stmt
  From f$.GenDropObj(@name, @silent) as ToDrop
  Exec (@Sql)
End -- f$.DropObj 
GO
If object_id('f$.CleanupLibraryObjects') is not null 
  drop procedure f$.CleanupLibraryObjects
GO
--f$SignatureForCleanup
create Procedure f$.CleanupLibraryObjects  @Silent int = 0
as
Begin
  Set nocount on
  If Object_id('Tempdb..#todrop') IS NOT NULL Drop Table #todrop -- not using any externan
  ;With 
    ObjectsToDrop as
    (
    Select OBJECT_SCHEMA_NAME(Object_id)+'.'+Obj.Name as ObjName
    From sys.objects Obj
    Where Obj.is_ms_shipped = 0 
      And Object_Schema_name (Obj.object_id) = 'f$' 
      And 'f$.' + Name NOT IN ('f$.ObjectInfo', 'f$.GenDropObj', 'f$.DropObj', 'f$.CleanupLibraryObjects', 'f$.DropTempTb')
      And (   Obj.type IN ('FN', 'TF', 'IF', 'P', 'SN', 'V') -- fonction procedures synonymes vues, mais conserve les tables
           Or (Obj.type_desc = 'User_Table' And Name Like 'ErrorLogStack[0-9]%[0-9]')
           Or (Obj.type_desc = 'User_Table' And Name Like 'RealScriptToRun')
          )
      And (
             Object_definition(obj.object_id) Like '%--f$SignatureForCleanup%'
          Or Obj.type_desc = 'User_Table'
          ) 
    )
  Select ToDrop.Stmt, ROW_NUMBER() Over (Order By ToDrop.FqqDbName) as Seq 
  Into #ToDrop
  From 
    ObjectsToDrop as Obj
    cross apply f$.GenDropObj (Obj.ObjName, @Silent) as ToDrop

  Create Index iToDrop On #ToDrop (seq)
  Declare @Seq Int = 0
  Declare @Sql Nvarchar(max)
  While (1=1)
  Begin
    Select top 1 @Seq=Seq, @Sql=Stmt From #ToDrop Where seq > @Seq
    If @@ROWCOUNT = 0 Break;
    Exec (@Sql)
  End

  exec ('Drop Function f$.ObjectInfo')
  exec ('Drop Function f$.GenDropObj')
  exec ('Drop Proc f$.DropObj')
  exec ('Drop Proc f$.DropTempTb')
  exec ('Drop Proc f$.CleanupLibraryObjects')
End -- f$.CleanupLibraryObjects 
GO
Exec f$.DropObj 'f$.GlobalEnumsOfF$'
GO

Exec f$.DropObj 'f$.FP4TSQLVersionInfo'
GO
--f$SignatureForCleanup
Create Function f$.FP4TSQLVersionInfo () -- detection de bug quand valeurs anormales de remplacement
Returns Table
as
Return 
(
With 
  basicVerInfo as (Select 2 as major, 1 as Minor, 0 as Build, '2015-11-14' as VersionDate)
Select 
  Str(major, 7)+Str(minor, 7)+Str(build, 7) as versionToCompare
, Convert(nvarchar, major)+'.'+Convert(nvarchar, minor)+'.'+Convert(nvarchar, build) as versionToDisplay
, *
From 
  basicVerInfo
)
GO
Exec f$.DropObj 'f$.SQLVersionInfo'
GO
--f$SignatureForCleanup
Create Function f$.SQLVersionInfo () -- detection de bug quand valeurs anormales de remplacement
Returns Table
as
Return 
(
Select 
  convert(int, SERVERPROPERTY('ProductMajorVersion')) as ProductMajorVersion
, convert(int, SERVERPROPERTY('ProductMinorVersion')) as ProductMinorVersion 
, convert(int, SERVERPROPERTY('ProductLEVEL')) as ProductLevel
--select * from f$.SQLVersionInfo ()
)
GO
-- -------------------------------------------------------------------------------------------
-- Shorthand cast workaround to help cleaning up XML concat limited by default at 4000 char
-- and many other uses where a string expression has to become nvarchar(max) string
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.CMax'
GO
--f$SignatureForCleanup
CREATE function f$.CMax (@Val nvarchar(max)) -- pour alléger écriture des concaténations
Returns nvarchar(max)
as
Begin
  return (@val)
End
GO
-- --------------------------------------------------------------------------------------------
-- Shorthand to generate cr/lf
-- --------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.Nl'
GO
--f$SignatureForCleanup
CREATE function f$.Nl () -- pour alléger écriture des concaténations ajout de saut de ligne
Returns nvarchar(max)
as
Begin
  return (nchar(13)+nchar(10))
End
GO
---------------------------------------------------------------------------------------
-- pReplace : Input validation : Detect replacement from or by null parameters         
--            Add input validation to iReplace or iQReplace                            
---------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.pReplace'
GO
----f$SignatureForCleanup
--Create Function f$.pReplace (@fctName sysname, @What nvarchar(max), @From nvarchar(max), @To nvarchar(max)) -- detection de bug quand valeurs anormales de remplacement
--returns nvarchar(max)
--as 
--Begin
--return 
--  (
--  Select replace (@What, @From, @To) as s
--  Where @What is not null and @From is not null and @To is not null 
--  UNION ALL
--  Select convert(nvarchar(max),':Invalid params ') 
--        +'{@From}:{'+isnull(@From, 'NULL')+'} '+nchar(13)+nchar(10) 
--        +'{@To}:{'+isnull(@To, 'NULL')+'}' +nchar(13)+nchar(10)
--        +'{@What}:{'+isnull(@What, 'NULL')+'}'
--  Where @What is null OR @From is null Or @To is null 
--  )
--End
--f$SignatureForCleanup
Create Function f$.pReplace (@fctName sysname, @What nvarchar(max), @From nvarchar(max), @To nvarchar(max)) -- detection de bug quand valeurs anormales de remplacement
returns nvarchar(max)
as 
Begin
--f$SignatureForCleanup
  return 
  (
  case 
    When @What is not null and @From is not null and @To is not null 
    then replace (@What, @From, @To)
    Else @Fctname
       +':Invalid params '+
       +'{@From}:{'+isnull(@From, 'NULL')+'} '
       +'{@To}:{'+isnull(@To, 'NULL')+'}' +f$.Nl()
       +'{@What}:{'+isnull(@What, 'NULL')+'}'
  End 
  )
End
GO
---------------------------------------------------------------------------------------
-- Shorthand to replace a string by another and allows to do it in a pipeline manner
-- which avoids nested coding of multiple replacement. Very useful when generating
-- dynamic SQL queries for scripting.
---------------------------------------------------------------------------------------
exec f$.DropObj 'f$.iReplace'
GO
--f$SignatureForCleanup
create function f$.iReplace -- pour alléger écriture des remplacements par cross apply
( 
@What nvarchar(max), @From nvarchar(max), @To nvarchar(max)
)
Returns Table 
as
Return 
(
Select f$.pReplace ('f$.iReplace', @What, @From, @To) as s 
--Select s From f$.pReplace ('f$.iReplace', @What, @From, @To) 
--Select * from f$.iReplace('aa', 'a', 'b')
--Select * from f$.iReplace('aa', null, 'b')
--Select * from f$.iReplace('aa', 'a', null)
--Select * from f$.iReplace(null, 'a', null)
--Select * from f$.iReplace(null, null, null)
)
GO
---------------------------------------------------------------------------------------
-- Same as previous function, but add an extra replacement of double quotes by 
-- single quotes. Even more useful when generating dynamic SQL queries for scripting
-- but not always necessary.
---------------------------------------------------------------------------------------
exec f$.DropObj 'f$.iQReplace'
GO
--f$SignatureForCleanup
create function f$.iQReplace -- pour alléger écriture des remplacements par cross apply
( 
@What nvarchar(max), @From nvarchar(max), @To nvarchar(max)
)
Returns Table 
as
Return (Select Replace(f$.pReplace ('f$.iQReplace', @What, @From, @To), '"', '''') as s)
--Return (Select Replace(s, '"', '''') as S from f$.pReplace ('f$.iQReplace', @What, @From, @To))
GO
Exec f$.DropObj 'f$.[GlobalEnumsOfF$]'
GO
--f$SignatureForCleanup
Create View f$.[GlobalEnumsOfF$] as
Select
  '#SilentModeParameterFromRunScript#' as TagReplaceForSilentMode
, 'Bug : Le paramètre texte de la requête à imprimer est Null !!' as MsgQueryTextToPrintIsNULL
, 'Traitement interrompu, consulter la sortie pour la cause de l''erreur' as MsgForStopOnError
Where @@LANGUAGE = 'FRENCH'
UNION ALL
Select
  '#SilentModeParameterFromRunScript#' as TagReplaceForSilentMode
, 'Bug : Query text parameter Is Null !!' as MsgQueryTextToPrintIsNULL
, 'Processing stopped on error, see processing output for error printout' as MsgForStopOnErreur
Where @@LANGUAGE NOT IN ('FRENCH')
GO
-- ------------------------------------------------------------------------------
-- Search a string backward from end of another string and give distance from end
-- ------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RevSrchCharIndexFromEnd'
GO
--f$SignatureForCleanup
Create function f$.RevSrchCharIndexFromEnd(@srch nvarchar(max), @str nvarchar(max)) 
returns Int
as 
Begin
  Return (Case When Charindex(reverse(@srch), Reverse(@Str)) = 0 Then 0 Else Charindex(reverse(@srch), Reverse(@Str)) -1+len(@srch) End )
  /*
  Select f$.RevSrchCharIndexFromEnd(' ', '12.3456.7890') -- returns 0
  Select f$.RevSrchCharIndexFromEnd('.', '12.3456.7890') -- returns 5
  Select f$.RevSrchCharIndexFromEnd('123456', 'hello.123456') -- returns 6
  */
End
GO
-- ------------------------------------------------------------------------------
-- Search a string backward from end of another string and give distance from 
-- start of the string, if not found gives 0
-- ------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RevSrchCharIndexFromStart'
GO
--f$SignatureForCleanup
Create function f$.RevSrchCharIndexFromStart(@srch nvarchar(max), @str nvarchar(max)) 
returns Int
as 
Begin
  Return 
  (
  Select Case 
           When f$.RevSrchCharIndexFromEnd(@srch, @Str) > 0 
           Then Len(@Str)-f$.RevSrchCharIndexFromEnd(@srch, @Str)+1
           Else 0
         End  
  )
  /*
  Select f$.RevSrchCharIndexFromStart('.', '12.4567.90A') -- returns 8
  Select f$.RevSrchCharIndexFromStart(' ', '12.4567.90A')  -- returns 0
  */
End
GO
-- ------------------------------------------------------------------------------
-- Returns part of string before a search string found by CharIndex
-- ------------------------------------------------------------------------------
Exec f$.DropObj 'f$.LeftBefore'
GO
--f$SignatureForCleanup
Create function f$.LeftBefore(@str nvarchar(max), @srch nvarchar(max)) 
returns nvarchar(max)
as 
Begin
  Return (Case When CharIndex(@srch, @Str)>1 Then Left(@Str, CharIndex(@srch, @Str)-1) Else @Str End)
  /* select left('abc', 0)
  Select f$.LeftBefore('.', '.12.3456.7890') -- must return '.'
  Select f$.LeftBefore('12.3456.7890', '.') -- must return '12'
  Select f$.LeftBefore('12.3456.7890', ' ') -- must return 12.3456.7890
  */
End 
GO
-- ------------------------------------------------------------------------------
-- Returns part of string before a search string found by RevSrchCharIndexFromStart
-- ------------------------------------------------------------------------------
Exec f$.DropObj 'f$.LeftBeforeRevSrch'
GO
--f$SignatureForCleanup
Create function f$.LeftBeforeRevSrch(@str nvarchar(max), @srch nvarchar(max)) 
returns nvarchar(max)
as 
Begin
  Return (Left(@Str, Case When f$.RevSrchCharIndexFromStart(@srch, @Str)=0 Then len(@Str)+1 Else f$.RevSrchCharIndexFromStart(@srch, @Str)-1 End))
  /*
  Select 
    f$.RevSrchCharIndexFromStart('.12.3456.7890', '.')
  , f$.LeftBeforeRevSrch('.', '.12.3456.7890') -- must return '.'  not found
  Select f$.LeftBeforeRevSrch('12.3456.7890', '.') -- must return '12.3456'
  Select 
    f$.RevSrchCharIndexFromStart(' ', '12.3456.7890')
  , f$.LeftBeforeRevSrch('12.3456.7890', ' ') -- must return 12.3456.7890
  */
End
GO
-- ------------------------------------------------------------------------------
-- Returns part of string before a search string found by CharIndex
-- ------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RightAfter'
GO
--f$SignatureForCleanup
Create function f$.RightAfter(@str nvarchar(max), @srch nvarchar(max)) 
returns nvarchar(max)
as 
Begin
  Return (Right(@Str, len(@str)-charindex(@srch, @Str)))
  /*
  Select f$.RightAfter('.', '12.3456.7890') -- not found, must return @str unchanged = '.'  
  Select f$.RightAfter('12.3456.7890', '.') -- must return '3456.7890'
  Select f$.RightAfter('12.3456.7890', ' ') -- must return 12.3456.7890 returns @str if @srch not found
  */
End
GO
-- ------------------------------------------------------------------------------
-- Returns part of string before a search string found by RevSrchCharIndexFromEnd
-- ------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RightAfterRevSrch'
GO
--f$SignatureForCleanup
Create function f$.RightAfterRevSrch(@str nvarchar(max), @srch nvarchar(max)) 
returns nvarchar(max)
as 
Begin
  Return (Case When f$.RevSrchCharIndexFromEnd(@srch, @Str)=0 Then @str Else Right(@Str, f$.RevSrchCharIndexFromEnd(@srch, @Str)-len(@srch)) End)
  /*
  Select f$.RightAfterRevSrch('.', 'anything') -- must return @str unchanged, '.'  not found
  Select f$.RightAfterRevSrch('12.3456.7890', '.7') -- must return '890' found
  Select f$.RightAfterRevSrch('12.3456.7890', ' ') -- must return 12.3456.7890 unchanged, ' ' not found
  */
End
GO

-- ------------------------------------------------------------------------------
-- Generete rows with a increasing sequential number from 1 to @n
-- Useful to generate loops between data as in creating all dates
-- between two date
-- ------------------------------------------------------------------------------
Exec f$.DropObj 'f$.NumsToGenLoop'
GO
--f$SignatureForCleanup
Create function f$.NumsToGenLoop(@n as BigInt) 
returns TABLE               
as 
Return 
(
With 
  L0 AS (select 1 as c union all Select 1 as c ) --2
, L1 as (select 1 as C From L0 as A Cross JOIN L0 as B ) --4
, L2 as (select 1 as C From L1 as A Cross JOIN L1 as B ) -- 16
, L3 as (select 1 as C From L2 as A Cross JOIN L2 as B ) -- 256
, L4 as (select 1 as C From L3 as A Cross JOIN L3 as B ) -- 65536
, L5 as (select 1 as C From L4 as A Cross JOIN L4 as B ) -- 4294967296
, nums as (Select ROW_NUMBER() OVER (Order by c) as loopIndex from L5) 
Select top(case when @n < 0 Then 0 else @n End) loopIndex  From Nums 
Where @n > 0
--Select max(loopIndex) From f$.NumsToGenLoop(1000)
--Select loopIndex From f$.NumsToGenLoop(1000)
--Select * From f$.NumsToGenLoop(-1)
)
GO
Exec f$.DropObj 'f$.NumsToGenLoopBetween'
GO
--f$SignatureForCleanup
Create function f$.NumsToGenLoopBetween(@low as BigInt, @High as BigInt) 
returns TABLE               
as 
Return 
(
With 
  L0 AS (select 1 as c union all Select 1 as c ) --2
, L1 as (select 1 as C From L0 as A Cross JOIN L0 as B ) --4
, L2 as (select 1 as C From L1 as A Cross JOIN L1 as B ) -- 16
, L3 as (select 1 as C From L2 as A Cross JOIN L2 as B ) -- 256
, L4 as (select 1 as C From L3 as A Cross JOIN L3 as B ) -- 65536
, L5 as (select 1 as C From L4 as A Cross JOIN L4 as B ) -- 4294967296
, nums as (Select ROW_NUMBER() OVER (Order by c) as rownum from L5) 
Select TOP(case when @high - @low + 1 < 0 Then 0 else @high - @low + 1 End ) @low + rownum - 1 as LoopIndex
From Nums 
Order By rownum
--Select * From f$.NumsToGenLoopBetween(2000, 6000) order by LoopIndex
--Select * From f$.NumsToGenLoopBetween(-5, -3) order by LoopIndex
--Select * From f$.NumsToGenLoopBetween(-3, -5) order by LoopIndex
)
GO
Exec f$.DropObj 'f$.AlignSQL'
GO
--f$SignatureForCleanup
create function f$.AlignSql
(
  @sql nvarchar(max)
, @Indent int
)
returns nvarchar(max)
as
Begin
  Declare @NbOfLn Int
  Declare @NextSql nvarchar(max)
  
  -- Align T-SQL to have leftmost code to start in column on
  Set @Sql = replace (@Sql, nchar(10), nchar(10)+' ')

  Set @NbOfLn = len(@sql) - len(replace(@sql, nchar(10)+' ', nchar(10)+''))
  
  If @NbOfLn > 0 
  Begin 
    While (1 = 1)
    Begin
      set @NextSql = replace (@sql, nchar(10)+' ', nchar(10)+'')        
      If len(@sql) - len(@NextSql) = @NbOfLn
        Set @sql = @NextSql
      Else 
        Break  
    End  -- while
    If @Indent-1 > 0
      Set @Sql = replace (@Sql, nchar(10), space(@Indent-1))
  End
  Return (@sql)

  /*
  Select f$.AlignSQL(
  '
  Select 
    *
  From 
    Tb
  ',10)

  Select f$.AlignSQL(
  '
Select 
  *
From 
  Tb
  ',10)
  */
End -- f$.AlignTSQL
GO
Exec f$.DropObj 'f$.RPad'
GO
-- -------------------------------------------------------------------------------------------
-- Right padding space function.  
-- -------------------------------------------------------------------------------------------
--f$SignatureForCleanup
Create Function f$.RPad (@s nvarchar(max), @l int)  
Returns nvarchar(max)
As
Begin
  Return (Left(isnull(@s,'')+Space(@l), @l))
-- select '|'+f$.Rpad('12', 5)+f$.Rpad('6', 4)+'|'
-- |12   6   |
-- select f$.rpad('TREM16089107',12)+'!'
End
GO
-- ----------------------------------------------------------------------------------------
-- This function allows to extract delimited comment (generally code) code from text
-- and is used either by GetCommentFromBatch or directly from any text (generally the definition of a SP)
-- This allow to extract sql code put in comment between starting and ending delimitors
-- without having to worry about quotes.
exec f$.DropObj 'f$.GetDelimitedCommentFromText'
GO
--f$SignatureForCleanup
Create Function f$.GetDelimitedCommentFromText (@txt as nvarchar(max), @CommentTag nvarchar(max), @SourceTxt nvarchar(max) )
Returns table
as
Return
(
With 
  Prm as
  (
  Select @CommentTag as CT, @txt as Txt, @SourceTxt as SourceTxt
  --Select 'Testfail' as CT, '  some other text  /*Test Create view Test as Select 1 Test*/   --some other text' as txt, ' texte source '
  )
, CtInf as
  (
  Select 
    *
  , charindex('/*'+CE.CT, CE.Txt) as Start
  , charindex(CE.CT+'*/', CE.Txt) as EndP
  , LEN(Ct) as LgCt
  From Prm CE
  )
  --Select * From CtInf
, TxtContent as
  (
  Select 
    CtInf.CT as CommentTag
  , CtInf.Txt
  , InTxtContent.Lg
  , InTxtContent.StartP
  , InTxtContent.EndP
  , Case 
      When InTxtContent.Lg > 0 
      Then convert(nvarchar(max), Substring(Txt, InTxtContent.StartP, InTxtContent.EndP-InTxtContent.StartP+1) )
      Else RaiserrorNotFoundTxt -- '!No comments in ... with start and end tags /*#CtInf.CT#  #CtInf.CT#*/!'
    End as CommentContent
  From 
    CtInf
    OUTER APPLY -- produce alternate results depending start and end values
    (
    Select 
      Case When CtInf.Start = 0 Or CtInf.EndP = 0 Then 0 Else CtInf.EndP - (CtInf.Start + CtInf.LgCT) End as Lg
    , Case When CtInf.Start = 0 Or CtInf.EndP = 0 Then 0 Else charindex('/*'+CtInf.CT, Txt)+2+CtInf.LgCT End StartP
    , Case When CtInf.Start = 0 Or CtInf.EndP = 0 Then 0 Else charindex(CtInf.CT+'*/', Txt)-1 End EndP
    , r1.s As RaiserrorNotFoundTxt
    From 
      f$.IReplace('!No comment text in #source# between start tag /*#CtInf.CT# and end tag #CtInf.CT#*/!', '#CtInf.CT#', CtInf.CT) as r0
      CROSS APPLY f$.IQReplace(r0.s, '#source#', ISNULL(SourceTxt, ' in source text ')) as r1
    ) as InTxtContent
  )
Select * From TxtContent

  --declare @t nvarchar(max) =
  --'
  --select ''some other text''
  --/*Test
  --Create view Test as Select 1
  --Test*/
  --'
  --declare @t2 nvarchar(max) =
  --'
  --select ''some other text''
  --/*TestNonMatch
  --Create view Test as Select 1
  --Test*/
  --'
  --declare @t3 nvarchar(max) =
  --'
  --select ''some other text''
  --/*Test
  --Create view Test as Select 1
  --TestNonMatch*/

  ----some other text
  --'
  --Select * From f$.GetDelimitedCommentFromText(@t, 'test', NULL)
  --Select * From f$.GetDelimitedCommentFromText(@t2, 'testNonMatch', 'Dans aute source')
  --Select * From f$.GetDelimitedCommentFromText(@t3, 'test2', NULL)

)
GO

-- ----------------------------------------------------------------------------------------
-- This function allows to extract code from a comment into a batch
-- This allow to create sql code object by putting it in comment without having to worry about quotes
-- and create it with the help of f$.ScriptToRun and f$.RunScriptTable
-- ex:
-- /*CommentTag
-- code in comment
-- CommentTag*/
-------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.GetCommentFromBatch'
GO
--f$SignatureForCleanup
Create Function f$.GetCommentFromBatch (@CommentTag nvarchar(max))
Returns table
as
Return
(
  With 
    Prm as
    (
    Select @CommentTag as CommentTag
    --Select 'Testfail' as CommentTag
    )
  , CurrentlyExecutingBatchText as 
    (
    Select qt.text  Collate Database_Default as batchTxt, CommentTag as CT, Len(CommentTag) as LgCT
    From 
      Prm 
      cross join
      sys.dm_exec_requests er
      Cross Apply 
      sys.dm_exec_sql_text(er.sql_handle) as qt
    Where er.session_id = @@SPID
    )
  Select T.CommentTag, T.Txt, T.Lg, T.StartP, T.EndP, T.CommentContent as BatchComment
  From 
    CurrentlyExecutingBatchText as CE
    CROSS APPLY f$.GetDelimitedCommentFromText(CE.batchTxt, CE.CT, 'Sql batch text') as T
  /*
  /*Test
  Create view Test as Select 1
  Test*/
  Select * From f$.GetCommentFromBatch('test')

  /*test2
  In test 2
  test2*/
  Select * From f$.GetCommentFromBatch('test')

  */
)
GO
-- ----------------------------------------------------------------------------------------
-- This function allows to extract code from a comment into SQL Code objet, like a view
-- or a inline table function.
--
-- GetCommentFromBatch works to get code in executing SP but not in view or Inline table function
-- this is why this function is needed, when the inline function holds itself the comment
-- and we want to extract code from the comment
--
-- ex:
-- /*CommentTag
-- code in comment
-- CommentTag*/
-------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.GetCommentFromSqlObj'
GO
--f$SignatureForCleanup
Create Function f$.GetCommentFromSqlObj(@ObjectId Int, @CommentTag nvarchar(max))
Returns table
as
Return
(
  --With PrmToCols (ObjectId, CommentTag) As (Select object_id('f$.GetCommentFromSqlObj'), '--Test--') 
  With PrmToCols (ObjectId, CommentTag) As (Select @ObjectId, @CommentTag) 
  Select T.*
  From 
    PrmToCols 
    CROSS APPLY f$.GetDelimitedCommentFromText(object_definition (ObjectId), CommentTag, ' in '+OBJECT_NAME(ObjectId)) as T
  /*--Test--
  Select * From f$.GetCommentFromSqlObj(object_id('f$.GetCommentFromSqlObj'), '--Test--')
  --Test--*/
)
GO
-- ----------------------------------------------------------------------------------------
-- This procedure allows to justify text that can come from many place but it can also 
-- a way to return a justified text comment provide is has a starting and ending tag
-- as in the following example
-- ex:
/*
  /*c3
Here are many  lines of texts to 

remove and some more text to see if it works
  C3*/
  Select f$.Justifytxt(BatchComment, 15)
  From f$.GetCommentFromBatch ('C3')
*/
-------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.JustifyTxt'
GO
--f$SignatureForCleanup
Create Function f$.JustifyTxt(@txt nvarchar(max), @txtWidth int)
Returns Nvarchar(max)
as
Begin
  Set @Txt = replace(@txt, nchar(13)+nchar(10)+nchar(13)+nchar(10), '\\')

  Declare @Jtxt nvarchar(max) = 
  replace(replace(replace(@txt, nchar(13)+nchar(10), ' '), nchar(13), ''), nchar(10), '')

  Set @jTxt = Replace(@jTxt, '\\',  nchar(13)+nchar(10)+nchar(13)+nchar(10))

  Declare @i int;
  Declare @lgTxt int;
  Declare @lastPossibleLineEnd int;
  Declare @lineLen Int;

  Set @i = 0;
  Set @lgTxt = LEN(@jTxt);
  Set @lastPossibleLineEnd = 0;
  Set @lineLen = 0;

  While (@i < @lgTxt)
  Begin
    If SUBSTRING(@Jtxt, @i, 1) = nchar(10)
    Begin 
      Set @lastPossibleLineEnd = 0;
      Set @lineLen = 0;
    End

    Set @lineLen = @lineLen + 1
    Set @i = @i + 1
    If @lineLen > @txtWidth
      If @lastPossibleLineEnd > 0
      Begin
        Set @Jtxt = STUFF(@jTxt, @lastPossibleLineEnd, 1, nchar(13)+nchar(10))
        Set @lgTxt = @lgTxt + 1
        Set @lastPossibleLineEnd = 0
        Set @lineLen = 0
      End

    If SUBSTRING(@Jtxt, @i, 1) = ' '
      --If @lastPossibleLineEnd < @txtWidth 
        Set @lastPossibleLineEnd = @i
  End;
  If @lastPossibleLineEnd > 0 And @lineLen > @txtWidth
    Set @Jtxt = STUFF(@jTxt, @lastPossibleLineEnd, 1, nchar(13)+nchar(10))

  return(@jtxt)
/*
/*Test3
Create view Test as Select 1 as test3 and somelonglongtextelonguertahmaxwidth more text to see if it works and and and andee
Test3*/
Select f$.Justifytxt(BatchComment, 15)
From f$.GetCommentFromBatch ('Test3')
*/
End
GO
-- ----------------------------------------------------------------------------------------
-- This procedure allows to justify a comment 
/*
s*/
-------------------------------------------------------------------------------------------

exec f$.DropObj 'f$.JustifyTxtInComment'
GO
--f$SignatureForCleanup
Create Function f$.JustifyTxtInComment(@commentTag nvarchar(4000), @txtWidth int)
Returns Table
as
Return
(
Select f$.Justifytxt(BatchComment, @txtWidth) as FormattedComment
From f$.GetCommentFromBatch (@commentTag)
)
GO
-- -------------------------------------------------------------------------------------------
-- Help printing out SQL Code, by dividing lines at cr/lf
-- Workaround for SQL Print output limited to 8000 chars in SQL Management Studio 
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.SplitSqlCodeLinesIntoRows'
GO
--f$SignatureForCleanup
Create Function f$.SplitSqlCodeLinesIntoRows(@Sql Nvarchar(Max))
returns @TxtSql table (LineNum int, Line nvarchar(max) not null default '')
As
Begin
  Declare @LineNo Int

  If @Sql Is Null Or @Sql = ''
  Begin
    Return
  End

  Set @Sql = REPLACE(@Sql, f$.Nl(), NCHAR(10))
  Set @Sql = REPLACE(@Sql, NCHAR(13), NCHAR(10))

  Declare @Start Int, @End Int, @Line Nvarchar(Max), @EolPos Int
  Set @Start = 1 
  Set @End=0
  Set @LineNo = 0

  While(@End < LEN(@Sql))
  Begin
    Set @EolPos = CHARINDEX(NCHAR(10), @Sql, @Start)
    Set @End = Case When @EolPos > 0 Then @EolPos Else LEN(@Sql)+1 End -- End of String @Sql
       
    Set @LineNo = @LineNo + 1
    
    insert into @TxtSql (LineNum, Line)
    Values (@lineNo, SUBSTRING(@Sql, @Start, @End-@Start))

    Set @Start = @End+1
  End
  Return;
End
GO
Exec f$.DropObj 'f$.SplitSqlCodeInNumberedRowLines'
GO
--f$SignatureForCleanup
Create Function f$.SplitSqlCodeInNumberedRowLines(@Sql Nvarchar(Max))
Returns table
as
Return (select LineNum, '/* '+STR(LineNum,5)+' */'+Line as Line from f$.SplitSqlCodeLinesIntoRows(@Sql))
GO
Exec f$.DropObj 'f$.SplitSqlCodeInRowLines'
GO
--f$SignatureForCleanup
Create Function f$.SplitSqlCodeInRowLines(@Sql Nvarchar(Max))
Returns table
as
Return (select LineNum, Line from f$.SplitSqlCodeLinesIntoRows(@Sql))
GO
-- -------------------------------------------------------------------------------------------
-- Register log table for RunScriptToRun and create a function that returns its name
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RegisterLogTable'
GO
--f$SignatureForCleanup
Create Procedure f$.RegisterLogTable @LogTable sysname = NULL
As
Begin
  Set Nocount On

  Declare @Sql nvarchar(max)

  Set @Sql = 'If Object_Id(''f$.LogTable'') IS NOT NULL DROP Function f$.LogTable'
  Exec (@Sql)

  Set @Sql = '
  --f$SignatureForCleanup
  Create function f$.LogTable () Returns sysname as Begin Return("#logTable#") End'
  Select @Sql = r0.s From f$.iQReplace(@Sql, '#logTable#', ISNULL(@LogTable,'')) as r0
  Exec (@Sql)
  
  If isnull(@logTable,'') = '' Return
  Set @Sql =
  '
  Exec f$.DropObj "#logTable#", @silent=1
  Create table #logTable# (Line nvarchar(max), seq int identity, batchNo BigInt)
  Create index [i#logTable#] on #logTable# (batchNo desc)
  '
  Select @Sql = r0.s From f$.iQReplace(@Sql, '#logTable#', ISNULL(@LogTable,'')) as r0
  Exec (@Sql)
End
GO
Exec f$.RegisterLogTable -- par défaut pas de table de log
--Exec f$.RegisterLogTable 'aLogTable'-- test it
GO
exec f$.DropObj 'f$.QueryLog'
go
--f$SignatureForCleanup
Create Procedure f$.QueryLog @like nvarchar(max) = NULL, @NomLog sysname = NULL
as
Begin
  Set Nocount On

  declare @sql nvarchar(max);
  With 
    PrepQry as 
    (
    Select 
      '
      ;With 
        -- locate batch number where there is at least 1 line that match like
        Batch as (select distinct batchno from #LogTable# where Line like @like)
      Select Line
      From 
        Batch B
        Join 
        #LogTable# M  -- locate lines of found batches
        ON M.batchNo = B.batchNo
      order by M.batchNo, seq -- print them ordered
      ' as QryLike
    , 'Select Line from #LogTable# order by batchNo, seq' as QryPLain
    , ISNULL(@NomLog, (Select f$.LogTable())) as LogTable 
    )
  , PrepQryStep2 as
    (
    Select 
      Case 
        When LogTable = ''
        Then 'Print "il n""y a pas de log par défaut. Utiliser f$.RegisterLogTable avec un nom de log"'
        Else Case When @like IS NULL Then QryPLain Else QryLike End 
       End as Qry
     , *
    From PrepQry
    )
  Select @sql = r0.s
  From 
    PrepQryStep2 as P
    cross apply f$.iQReplace(Qry, '#LogTable#', LogTable) as r0
  Print @sql
  Exec sp_executeSql @sql, N'@Like nvarchar(max), @NomLog Sysname', @like, @NomLog
End
GO
Exec f$.DropObj 'f$.PrintAndLogCode'
GO
--f$SignatureForCleanup
Create Function f$.PrintAndLogCode ()
Returns Table
as
Return
(
With 
  Template as
  (
  Select 
    '
    Print @LogText;
    #InsertToLog#
    ' as PrintSql
  , 'With 
      TopBatchNo (batchNo) as
      (
      Select 0 Where Not Exists (Select * From #logTable#)
      UNION ALL
      Select top 1 batchNo From #logTable# Order By BatchNo Desc 
      )
    Insert into #LogTable# (line, batchNo) Select @LogText, BatchNo+@NextBatch From TopBatchNo 
    ' as InsertToLog
  )
  Select 
    r1.s as SqlToPrintAndLog
  From
   Template
   CROSS APPLY f$.IReplace (PrintSql, '#InsertToLog#', Case When Object_id(f$.logTable()) IS NOT NULL Then InsertToLog Else '' End) as r0
   CROSS APPLY f$.IReplace (r0.s, '#LogTable#', f$.LogTable()) as r1

  /*
  Exec f$.RegisterLogTable ''
  Select * From f$.PrintAndLogCode()
  Exec f$.RegisterLogTable 'f$.LogTest'
  Select * From f$.PrintAndLogCode()
  Drop Table f$.LogTest
  Select * From f$.PrintAndLogCode()
  */
)
GO
-- -------------------------------------------------------------------------------------------
-- Print messages and log to a table if necessary
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.PrintAndLog'
GO
--f$SignatureForCleanup
Create Procedure f$.PrintAndLog
  @LogText Nvarchar(Max)
, @nextBatch Int = 0
As
Begin
  Set Nocount On
  Declare @SqlToPrintAndLog nvarchar(max) 
  Select @SqlToPrintAndLog = SqlToPrintAndLog  From f$.PrintAndLogCode ()
  Exec Sp_ExecuteSql @SqlToPrintAndLog, N'@LogText Nvarchar(Max), @nextBatch Int', @LogText, @nextBatch

  /*
  Exec f$.RegisterLogTable ''
  Exec f$.PrintAndLog 'test text', 0
  Exec f$.RegisterLogTable 'f$.LogTest'
  Exec f$.PrintAndLog 'test text', 1
  Exec('Select * from f$.LogTest')
  Exec f$.PrintAndLog 'next test text', 0
  Exec('Select * from f$.LogTest')
  Exec f$.PrintAndLog 'next batch test text', 1
  Exec('Select * from f$.LogTest')
  */
  End
GO
-- -------------------------------------------------------------------------------------------
-- Wrap around previous function in which error messages are not allowed
-- This procedure add error message if text of the query to print is found NULL
-- and add a workaround to help push out faster print output to client
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.PrintSplittedSqlCode'
GO
--f$SignatureForCleanup
Create Procedure f$.PrintSplittedSqlCode 
  @Sql Nvarchar(Max)
, @Label Nvarchar(Max) = Null
, @NextBatch Int = 1
As
Begin
  Set Nocount On

  If @Label Is Not Null
  Begin
    Select @Label = '/* ' + @Label + ' */'
    Exec f$.PrintAndLog @Label, 1
    Set @NextBatch = 0
  End

  If @Sql Is Null 
  Begin
    Select @Sql = E.MsgQueryTextToPrintIsNULL From f$.GlobalEnumsOfF$ E
    Print @sql
    Return
  End

  Declare QueryCursor Cursor Local FORWARD_ONLY
  For Select Line From f$.SplitSqlCodeInNumberedRowLines(@Sql) Order By LineNum
  Open QueryCursor 

  Declare @s nvarchar(max)
  While(1=1)
  Begin
    Fetch Next From QueryCursor Into @s
    If @@FETCH_STATUS = 0
    Begin
      Exec f$.PrintAndLog @s, @NextBatch
      Set @NextBatch = 0
    End
    Else 
      Break
  End
  Raiserror ('',10,1) With NoWait -- force Print Output  
  Close QueryCursor 
  Deallocate QueryCursor 

  /*
  Declare @Sql nvarchar(max) =
  '
  Select *
  From 
    UnitTest
  '
  Exec f$.RegisterLogTable ''
  Exec f$.PrintSplittedSqlCode @Sql, '*** label ****', 1
  Exec f$.RegisterLogTable 'f$.LogTest'
  Exec f$.PrintSplittedSqlCode @Sql, '*** label ****', 1
  Exec('Select * from f$.LogTest')
  Exec f$.PrintSplittedSqlCode 'Some Extra', NULL, 0
  Exec('Select * from f$.LogTest')
  Exec f$.PrintSplittedSqlCode @Sql, NULL, 1
  Exec f$.PrintAndLog 'log this message in same batch', 0
  Exec('Select * from f$.LogTest')

  */

End
GO
-- -------------------------------------------------------------------------------------------
-- Standard formatting of SQL try-catch error
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.PrintErrorDetails'
GO
--f$SignatureForCleanup
Create Proc f$.PrintErrorDetails @Sql Nvarchar(max) = ''  -- use case : When SQL text is not loggued into a table, caller must supply this parameter
as
Begin
  Set Nocount On

  Declare @ErrLine Int
  Declare @Msg Nvarchar(Max)
  Declare @DiagReq Nvarchar(Max)

  Declare @insert nvarchar(max) 

  Set @Msg = 
    Replicate ('-', 50)+' Error from f$.RunScript when running script above '+Replicate ('-', 50)+f$.Nl()+
    ERROR_MESSAGE() + f$.Nl() +
    'Error:' + CONVERT(Nvarchar(6),Error_Number ()) +
    ' Severity:' + CONVERT(Nvarchar(6),ERROR_SEVERITY()) +
    ' State:' + CONVERT(Nvarchar(6),ERROR_STATE()) +
    Case When ERROR_LINE () Is Not Null
      Then '   at line:' + CONVERT(Nvarchar(7),ERROR_LINE())
      Else ''
    End + f$.Nl() + 
    Replicate ('-', 150)+f$.Nl()

  If @Sql <> ''  
    Exec f$.PrintSplittedSqlCode @Sql = @Sql

  Set @Sql = 
  '
  If Object_ID("f$.ErrorLogStack#Spid#") IS NULL
    Create Table f$.ErrorLogStack#Spid# (msg nvarchar(max))

  If Not Exists (Select * From f$.ErrorLogStack#Spid# Where Msg = @Msg) 
  Begin
    Insert into f$.ErrorLogStack#Spid# (Msg) Values (@Msg)
    Exec f$.PrintAndLog @Msg, 0
End
  '
  Select @Sql = r0.s From f$.iQReplace(@sql, '#Spid#', convert(nvarchar, @@Spid)) as r0
  Exec SP_executeSql @Sql, N'@msg nvarchar(max)', @Msg
End
GO
-- -------------------------------------------------------------------------------------------
-- Monitoring : Extract actual query running in a batch
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ActiveQueryInBatch'
GO
--f$SignatureForCleanup
create function f$.ActiveQueryInBatch(@batch nvarchar(max), @start int, @end int) 
returns table
return
(
  With CalcStartEnd as (Select (@start/2)+1 as start, (CASE @end When -1 Then DATALENGTH(@batch) Else @End End)/2+1 as Stringlen)
  Select 
    Case 
      When @Start > Len(@batch) Or @End > Len(@batch)
      Then @Batch
      Else SUBSTRING (@batch, start, Stringlen) 
    End as RunningQuery
  from CalcStartEnd 
);
GO
Exec f$.DropObj 'f$.SessionInfo'
GO
--f$SignatureForCleanup
create view f$.SessionInfo
as
select 
  isnull(q.RunningQuery, T.Text) as RunningQuery
, s.session_id as spid
, T.Text as QueryBatch
, db_name(r.database_id) as dbName
, r.blocking_session_id as BlockedBy
, s.host_name
, s.program_name
, s.status
, s.cpu_time
, s.memory_usage
, s.row_count
, s.total_scheduled_time
, s.total_elapsed_time
, s.reads
, s.writes
, s.logical_reads
, r.start_time
, r.percent_complete
, s.last_request_start_time
, s.last_request_end_time
, s.login_name
, s.client_interface_name
, s.client_version
, s.nt_domain
, s.nt_user_name
, s.context_info
, s.endpoint_id
, s.is_user_process
, s.language
, s.date_format
, s.date_first
, s.quoted_identifier
, s.arithabort
, s.ansi_null_dflt_on
, s.ansi_defaults
, s.ansi_warnings
, s.ansi_padding
, s.ansi_nulls
, s.concat_null_yields_null
, s.transaction_isolation_level
, s.lock_timeout
, s.deadlock_priority
, s.prev_error
, s.original_security_id
, s.original_login_name
, s.last_successful_logon
, s.last_unsuccessful_logon
, s.unsuccessful_logons
, s.login_time
, s.host_process_id
, C.protocol_version 
, C.net_transport 
, p.query_plan 
from 
  sys.dm_exec_sessions S
  left join
  sys.dm_exec_connections C
  On C.session_id = S.session_id  
  left join
  sys.dm_exec_requests R
  on R.session_id = s.session_id 
  outer apply
  sys.dm_exec_sql_text (r.sql_handle) as T
  outer apply
  f$.ActiveQueryInBatch(T.Text, r.statement_start_offset, r.statement_end_offset) as q
  outer apply 
  sys.dm_exec_query_plan(r.plan_handle) p

where s.program_name is not null And s.session_id <> @@spid And T.Text is Not null
GO
-- -------------------------------------------------------------------------------------------
-- Monitoring : Print currentQueries running 
-- -------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.CurrentQueries'
GO
--f$SignatureForCleanup
Create Proc f$.CurrentQueries 
as
Begin
  Set Nocount On

  Declare @qui nvarchar(max)
  Declare @Sql nvarchar(max)

  Select 
    @qui = '['+Str(spid,5) + ']' + dbName + '[' + status collate Database_default + ']' + login_name + '[' + host_name + ']' + program_name + '[Blk:' + convert(nvarchar(30), BlockedBy)+']' 
  , @Sql = Inf.RunningQuery 
  From 
    f$.SessionInfo Inf

  Declare QueryCursor Cursor Local FORWARD_ONLY
  For 
  Select 
    Sql.Line
  From 
    f$.SplitSqlCodeInNumberedRowLines(@sql) Sql
  Order By LineNum
  
  Open QueryCursor 

  Print '-----------------------------------------------------------------------------------'
  Print @qui
  Print '-----------------------------------------------------------------------------------'

  Declare @s nvarchar(max)
  While(1=1)
  Begin
    Fetch Next From QueryCursor Into @s
    If @@FETCH_STATUS = 0
    Begin
      Print @s
    End
    Else 
      Break
  End
  Close QueryCursor 
  Deallocate QueryCursor 

  -- Exec f$.CurrentQueries
End
GO
-- ------------------------------------------------------------------------------------------
-- List last batch loggued into a log table
-- ------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ShowLastQuerybatchInLog'
GO
--f$SignatureForCleanup
Create Proc f$.ShowLastQuerybatchInLog @LogTable sysname = NULL as
Begin
  Set Nocount On

  Declare @sql nvarchar(max)
  If COALESCE (@LogTable, f$.LogTable(), '') = ''
  Begin 
    Raiserror ('Supply @logtable parameter or register a logTable with f$.RegisterLogTable as default log table', 10, 1);
    Return
  End

  Set @Sql =
  '
  With 
    LastBatch (BatchNo) as (Select MAX(BatchNo) from #logTable# With (nolock))
  select Line
  from 
    LastBatch DB
    JOIN 
    #logTable# SL With (nolock) 
    ON SL.BatchNo = DB.BatchNo
  order by SL.seq
  '
  Set @sql = replace(@sql, '#logTable#', ISNULL(@LogTable, f$.LogTable()))
  Set @Sql = replace(@sql, '"', '''')
  Exec (@sql)

  /*
  Declare @Sql nvarchar(max) =
  '
  Select *
  From 
    UnitTest
  '
  Exec f$.RegisterLogTable ''
  Exec f$.PrintSplittedSqlCode @Sql, '*** etiquette ****', 1
  Exec f$.RegisterLogTable 'f$.LogTest'
  Exec f$.PrintSplittedSqlCode @Sql, '*** etiquette ****', 1
  Exec f$.PrintSplittedSqlCode 'Some Extra', NULL, 0
  Set @sql =
  '
  Select *
  From 
    UnitTest2
  '
  Exec f$.PrintSplittedSqlCode @Sql, NULL, 1
  Exec f$.ShowLastQuerybatchInLog 
  Exec f$.ShowLastQuerybatchInLog 'f$.LogTest'
  */

End
GO
-- ------------------------------------------------------------------------------------------
-- Table used to store commands to run (segregated by connection)
-- ------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ScriptToRun', 1  -- drop view built on it
Exec f$.DropObj 'f$.AppendToScriptToRun', 1 -- drop view built on it
Exec f$.DropObj 'f$.RealScriptToRun', 1 -- drop real table
Create Table f$.RealScriptToRun 
(
  spid int constraint DF_RealScriptToRun_Spid default @@spid
, nestLevel Int constraint DF_RealScriptToRun_nestLevel default @@NESTLEVEL -- allow reentrancy when working with this f$.ScriptToRun and f$.RunScript
, seq int 
, eventTime datetime2 constraint DF_RealScriptToRun_eventime default SYSDATETIME()
, Sql Nvarchar(max) 
, label nvarchar(max)
, constraint Pk_RealScriptToRun Primary Key Clustered (spid, nestLevel, seq)
)
GO
--f$SignatureForCleanup
Create View f$.ScriptToRun as Select Sql, label, Seq, nestLevel From f$.RealScriptToRun Where spid = @@spid
GO
-- ------------------------------------------------------------------------------------------
-- When inserting through this view, previous rows inserted are automatically cleanuped
-- ------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ScriptToRunInsertTrigger'
GO
--f$SignatureForCleanup
Create Trigger f$.ScriptToRunInsertTrigger
ON f$.ScriptToRun
Instead Of Insert
as
Begin
  Set nocount on
  Delete From f$.ScriptToRun Where nestLevel = @@NESTLEVEL-- this view is filtered by current @@spid
  Insert into f$.ScriptToRun (seq, Sql, label) Select  seq, Sql, label From Inserted
End
GO
--f$SignatureForCleanup
Create View f$.AppendToScriptToRun  as Select Sql, label, Seq, nestLevel From f$.RealScriptToRun Where spid = @@spid
GO
-- ------------------------------------------------------------------------------------------
-- When inserting through this view, previous rows inserted are not automatically cleanuped
-- It allows to add script lines in many inserts before running them
-- ------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.AppendToScriptToRunInsertTrigger'
GO
--f$SignatureForCleanup
Create Trigger f$.AppendToScriptToRunInsertTrigger
ON f$.AppendToScriptToRun
Instead Of Insert
as
Begin
  Set nocount on
  Insert into f$.AppendToScriptToRun (seq, Sql, label) Select  seq+(Select ISNULL(Max(Seq),0) From f$.ScriptToRun), Sql, label From Inserted
End
GO
-- ------------------------------------------------------------------------------------------
-- Clean table used to store commands to run (segregated by connection)
-- Almost Obsolete because each insert into RunScript does it by default
-- ------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.FlushScriptToRun'
GO
--f$SignatureForCleanup
Create Procedure f$.FlushScriptToRun
as 
Begin
  Set nocount on; 
  Delete From f$.ScriptToRun Where nestLevel = @@NESTLEVEL -- this view is filtered by current @@spid
End
GO
Exec f$.DropObj 'f$.ShowLastRunScriptQry'
GO
------------------------------------------------------------------------------
-- This function is altered at every query run by RunScript
-- It conveniently displays last running query attempted to be run
------------------------------------------------------------------------------
--f$SignatureForCleanup
Create Procedure f$.ShowLastRunScriptQry
as
/*===QueryToDisplay===
--actually nothing
===QueryToDisplay===*/
Select S.Line
From 
  f$.GetCommentFromBatch ('===QueryToDisplay===') as Sql
  cross Apply f$.SplitSqlCodeLinesIntoRows(Sql.BatchComment) S
Order by LineNum
Go
-- ------------------------------------------------------------------------------------------
-- Run store commands in scriptTable (segregated by connection)
-- ------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RunScript'
GO
--f$SignatureForCleanup
create Proc f$.RunScript @PrintOnly Int = 0, @Silent Int = 0, @NestLevelOffset int = 0, @RunOnThisDb sysname = NULL
as
Begin
  Set Nocount on;
  Declare @Sql Nvarchar(max)
  Declare @Label Nvarchar(max)
  Declare @seq Int
  Declare @d datetime
  Declare @SqlThatChangeShowLastRunScriptQry nvarchar(max)

  -- this table purpose is to avoid displaying the same error messages multiple times 
  -- when f$.RunScript is a nested manner, and throw is catched and retrow when returning
  -- from nested calls. 
  Set @Sql = 'If Object_ID("f$.ErrorLogStack#Spid#") IS NOT NULL Drop Table f$.ErrorLogStack#Spid#'
  Select @Sql = r0.s From f$.iQReplace(@sql, '#Spid#', convert(nvarchar, @@Spid)) as r0
    Exec (@Sql)

  Select @seq = Min(Seq)-1 
  From f$.ScriptToRun -- this view is filtered by current @@spid
  Where nestLevel = (@@NESTLEVEL + @NestLevelOffset) 

  Begin Try
    While (1=1)
    Begin
      Select Top 1 @seq = seq, @sql = sql, @Label = label 
      From f$.ScriptToRun -- this view is filtered by current @@spid
      Where nestLevel = (@@NESTLEVEL + @NestLevelOffset) 
        And seq > @Seq 
      Order by Seq

      If @@rowcount = 0 break

      -- The following feature is 
      -- not a essential part of the library, just a convenience, so 
      -- don't care to handle unexpected exception

/*===AlterProc f$.ShowLastRunScriptQry===
--f$SignatureForCleanup
Alter Procedure f$.ShowLastRunScriptQry
as
/*===QueryToDisplay===
#SQL#
===QueryToDisplay===*/
Select S.Line
From 
  f$.GetCommentFromBatch ('===QueryToDisplay===') as Sql
  cross Apply f$.SplitSqlCodeLinesIntoRows(Sql.BatchComment) S
Order by LineNum
===AlterProc f$.ShowLastRunScriptQry===*/

      Select @SqlThatChangeShowLastRunScriptQry = r1.s
      From
        f$.GetCommentFromBatch ('===AlterProc f$.ShowLastRunScriptQry===') as B
        -- replace has its limits, search value to replace needs to be less than page size
        Cross Apply f$.iReplace (B.BatchComment, '#Sql#', @Sql) as r1
      Begin try
        Exec (@SqlThatChangeShowLastRunScriptQry)
      End try
      Begin catch
      End Catch

      -- Special handling of '#SilentModeParameterFromRunScriptToRun#'.  When this proc is duplicated we don't want
      -- this parameter to be replaced
      Set @Sql=Replace(@Sql, '#SilentModeParameter'+'FromRunScriptToRun#', convert(nvarchar, @silent))  -- carrie on Silent mode if #Silent# tag is specified in queries to run
      set @d = getdate()
      If @Silent = 0
      Begin
        If @RunOnThisDb IS NOT NULL 
          Print '--Dynamic database context switch to '+@RunOnThisDb+' is done by f$.RunScript'
        Exec f$.PrintSplittedSqlCode @Sql, @Label
      End
      If @PrintOnly = 0
      Begin
        Declare @nbRangees Int
        Declare @StatsInfo nvarchar(max)
        If @RunOnThisDb IS NULL 
          Exec (@Sql)
        Else
          Begin -- Since Use is dynamically executed first, and then the exec statement is executed dynamically under this context
                -- create (view/function/procedure) works because there is no executable statement in the @sql 
            Declare @IndirectUse as nvarchar(max)
            Set @IndirectUse = 'Use ['+@RunOnThisDb+']; Exec (@Sql)'
            Exec sp_executeSql @IndirectUse, N'@Sql nvarchar(max)', @Sql
          End

        ;With 
          DiffsSec as (Select @@rowcount as nbOfRows, @d Start, datediff(ss, @d, getdate())/3600 nbOfHr, datediff(ss, @d, getdate())/60 nbOfMin, datediff(ss, @d, getdate()) nbOfSec)
        , Parts as (Select nbOfRows, start, getdate() [End], nbOfHr Hr, (nbOfMin- (nbOfHr*60)) mi, nbOfSec - ((nbOfHr*3600)+nbOfMin*60) ss From DiffsSec)
        , TxtParts as 
          (
          Select 
            convert(nvarchar, nbOfRows) as nbOfRows
          , convert(nvarchar, Start, 108) as Start
          , convert(nvarchar, [End], 108) as EndTime
          , replace(Str(Hr, 2)+':'+Str(Mi, 2)+':'+Str(Ss, 2), ' ', '0') as HrMiSecDuration From Parts
          )
        Select 
          @StatsInfo = f$.Nl() + case When nbOfRows <> '0' Then '--rows: '+nbOfRows Else '' End +'--duration: '+HrMiSecDuration+'  start/end: '+ Start + '/'+ EndTime + f$.Nl() + f$.Nl() 
        From TxtParts

        If @Silent = 0 
          Exec f$.PrintAndLog @StatsInfo, 0
      End
    End -- While
    -- cleanup of instructions dont is made through the insert trigger on the view f$.ScriptToRun
  End Try 
  Begin Catch
    If @Silent = 0 -- log table is there, error already loggued
      EXEC f$.PrintErrorDetails 
    Else  
      EXEC f$.PrintErrorDetails @Sql;  -- in silent mode we need to see the query responsible for the error

    Throw; -- 
  End Catch

  /*
    set nocount on
    -- test show all three queries
    Exec f$.RegisterLogTable ''
    Insert Into f$.ScriptToRun(sql, seq)
    Select top 3 r0.s,  row_Number() Over (Order by Name) as seq
    From 
      sys.tables 
      Cross Apply f$.iQReplace('Select "#Tb#" as Tb, count(*) from #Tb#', '#tb#', OBJECT_SCHEMA_NAME(object_id)+'.'+name) r0
    Exec f$.RunScript @PrintOnly=0

    -- test show all three queries and log them, display last query in log
    Exec f$.RegisterLogTable 'f$.LogTest'
    Insert Into f$.ScriptToRun(sql, seq)
    Select top 3 r0.s,  row_Number() Over (Order by Name) as seq
    From 
      sys.tables 
      Cross Apply f$.iQReplace('Select "#Tb#" as Tb, count(*)', '#tb#', OBJECT_SCHEMA_NAME(object_id)+'.'+name) r0
    Exec f$.RunScript @PrintOnly=0
    Select * from f$.LogTest
    exec f$.ShowLastQuerybatchInLog    

    -- test error trapping without log table
    Exec f$.RegisterLogTable ''
    Insert Into f$.ScriptToRun(sql, seq)
    Select 'select * from MakeAnErrorThisTableDoesntExist',  1
    Exec f$.RunScript @PrintOnly=0

    -- test nested call error trapping without log table
    Exec f$.RegisterLogTable ''
    Insert Into f$.ScriptToRun(sql, seq)
    Select 
    '
      Insert Into f$.ScriptToRun(sql, seq)
      Select ''select * from MakeAnErrorThisTableDoesntExist'',  1
      Exec f$.RunScript @PrintOnly=0
    ', 1 
    Exec f$.RunScript @PrintOnly=0


    -- test error trapping with log table
    Exec f$.RegisterLogTable 'f$.LogTest'
    Insert Into f$.ScriptToRun(sql, seq)
    Select 'select * from MakeAnErrorThisTableDoesntExist',  1
    Exec f$.RunScript @PrintOnly=0
    Exec f$.RegisterLogTable 'f$.LogTest'
    Select * from f$.LogTest -- error must also be recorded into table

    -- test nested call error trapping with log table
    Exec f$.RegisterLogTable 'f$.LogTest'
    Insert Into f$.ScriptToRun(sql, seq)
    Select 
    '
      Insert Into f$.ScriptToRun(sql, seq)
      Select ''select * from MakeAnErrorThisTableDoesntExist'',  1
      Exec f$.RunScript @PrintOnly=0
    ', 1 
    Exec f$.RunScript @PrintOnly=0
    Select * from f$.LogTest -- error must also be recorded into table

  */

End
GO
-- ----------------- fonction f$.SplitList ------------------------------------------------------------
-- Split a list in rows
-- -----------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.SplitList'
GO
--f$SignatureForCleanup
CREATE function f$.SplitList (@Sep nvarchar(max), @list nvarchar(max))
returns @items table (item nvarchar(max), seq int)
as
Begin
  declare @start as Int, @Next as Int, @seq as int, @item as nvarchar(max)
  select @start = 1, @seq = 0, @Next = 1
  
  While (@next > 0)
  Begin
    Select @seq = @seq + 1, @Next = CHARINDEX (@Sep, @list, @start)
    If @Next  > 0 
      Set @item = ltrim(SUBSTRING (@list, @start, @next-@start))
    Else  
      Set @item = ltrim(SUBSTRING (@list, @start, len(@list)+1-@start))

    Insert into @items values (nullif (@item, ''), @seq) 
    Set @start = @next+1  
  End
  return  
End
GO
-- ----------------- fonction f$.SplitList ------------------------------------------------------------
-- Split a list in rows
-- -----------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.SplitTwoList'
GO
--f$SignatureForCleanup
CREATE function f$.SplitTwoList (@Sep nvarchar(max), @list1 nvarchar(max), @list2 nvarchar(max))
returns @items table (item1 nvarchar(max), item2 nvarchar(max), seq int)
as
Begin
  declare @seq as int
  declare @start1 as Int, @Next1 as Int, @item1 as nvarchar(max)
  declare @start2 as Int, @Next2 as Int, @item2 as nvarchar(max)
  select @start1 = 1, @Next1 = 1
  select @start2 = 1, @Next2 = 1
  Set @list1 = Replace(@list1, Nchar(10), '')
  Set @list1 = Replace(@list1, Nchar(13), '')
  Set @list2 = Replace(@list2, Nchar(10), '')
  Set @list2 = Replace(@list2, Nchar(13), '')
  Set @seq = 0

  While (@next1 > 0)
  Begin
    Set @seq = @seq+1
    Select @Next1 = CHARINDEX (@Sep, @list1, @start1)
    If @Next1  > 0 
      Set @item1 = ltrim(SUBSTRING (@list1, @start1, @next1-@start1))
    Else  
      Set @item1 = ltrim(SUBSTRING (@list1, @start1, len(@list1)+1-@start1))
    Set @start1 = @next1+1  

    Select @Next2 = CHARINDEX (@Sep, @list2, @start2)
    If @Next2  > 0 
      Set @item2 = ltrim(SUBSTRING (@list2, @start2, @next2-@start2))
    Else  
      Set @item2 = ltrim(SUBSTRING (@list2, @start2, len(@list2)+1-@start2))
    Set @start2 = @next2+1  

    Insert into @items values (nullif (@item1, ''), nullif (@item2, ''), @seq) 
  End
  return  
End
GO
--Select * From f$.SplitTwoList (',', 'a,b,c,d,e,f', '0,1,2,3,4,5')
Exec f$.DropObj 'f$.SplitPairsList'
GO
--f$SignatureForCleanup
CREATE function f$.SplitPairsList (@seps nchar(2), @list nvarchar(max))
returns @items table (item1 nvarchar(max), item2 nvarchar(max), seq int)
as
Begin
  ;With 
    Prm as (Select left(@seps, 1) as PairsSep, right(@seps,1) as InPairSep)
  , CrossPairs as
    (
    Select 
      Pairs.seq
    , Pairs.item as PairItem
    , AtLeft.Item as LeftItem
    , AtRight.Item as RightItem
    , AtLeft.Seq as AtLeftSeq
    , AtRight.Seq as AtRightSeq
    , Max(AtRight.Seq) Over (Partition By Pairs.Seq) as maxOnRightSide
    From 
      Prm 
      CROSS APPLY f$.SplitList (PairsSep, @List) as Pairs
      cross apply f$.SplitList (inPairSep, Pairs.item) AtLeft
      cross apply f$.SplitList (inPairSep, Pairs.Item) AtRight
    )
  , CorrectionForMissingRightValue as 
    (
    Select P.AtLeftSeq, P.AtRightSeq, Case When P.maxOnRightSide='' Then NULL Else P.maxOnRightSide End as maxOnRightSide, P.PairItem, P.LeftItem, P.RightItem, P.seq 
    From CrossPairs P
    )
  Insert Into @Items
  Select LeftItem, case When AtRightSeq=1 Then NULL Else RightItem End, Seq
  From 
    CorrectionForMissingRightValue
  Where 
      AtLeftSeq = 1
  And AtRightSeq = maxOnRightSide 
  /*
  select * from f$.SplitPairsList (',|', 'a1|a2, b1|b2, c1|c2, d1|d2')
  select * from f$.SplitPairsList (',|', 'a1, b1|b2, c1, d1|d2')
  select * from f$.SplitPairsList (',|', '|a1, b1|b2, c1, d1|d2')
  select * from f$.SplitPairsList (',|', 'a1, b1|b2, c1, d1|d2, e')
  */
  Return
End
GO

-- ----------------- fonction f$.SelFromPairList ------------------------------------------------------------
-- Select the nth tuple from a list of 2 values tuples, if null is supplied for nth tuple
-- all of them are returned
-- -----------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.SelFromPairList'
GO
--f$SignatureForCleanup
CREATE function f$.SelFromPairList (@pairNo Int, @sep nchar(2), @list nvarchar(max))
returns table 
as
return
(
Select * 
From f$.SplitPairsList (@sep, @list)
Where seq = isnull(@pairNo, Seq)
/*
select * from f$.SelFromPairList (2,    ',|', 'a1|a2, b1|b2, c1|c2, d1|d2')
select * from f$.SelFromPairList (1,    ',|', 'a1|a2, b1|b2, c1|c2, d1|d2')
select * from f$.SelFromPairList (4,    ',|', 'a1|a2, b1|b2, c1|c2, d1|d2')
select * from f$.SelFromPairList (5,    ',|', 'a1|a2, b1|b2, c1|c2, d1|d2')
select * from f$.SelFromPairList (1,    ',|', 'a1, b1|b2, c1, d1|d2')
select * from f$.SelFromPairList (2,    ',|', 'a1, |b2, c1, d1|d2')
select * from f$.SelFromPairList (3,    ',|', 'a1, b1|b2, c1, d1|d2')
select * from f$.SelFromPairList (NULL, ',|', 'a1, b1|b2, c1, d1|d2, e')
*/
)
GO
---------------------------------------------------------------------------------------------------------
-- This function is useful to remove accented chars, and handle string casing and both
---------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ReShapeCaseAndAccents'
GO
--f$SignatureForCleanup
Create Function f$.ReShapeCaseAndAccents (@Str Nvarchar(max))
Returns table
As
Return
(  
  With 
    Prm as (select @Str Collate Latin1_General_CS_AI as s)
  , RemoveAccentsStep1 as
    (
    Select 
      distinct Prm.s, aAeEiIoOuUyYcCnN.s as NAS
    From     
      Prm 
      cross apply (select (Prm.s collate LATIN1_GENERAL_CS_AI) as s) as StartStr
      cross apply (select replace(startStr.s,         'a', 'a') ) as a (s)
      cross apply (select replace(a.s,                'A', 'A') ) as aA (s)
      cross apply (select replace(aA.s,               'e', 'e') ) as aAe (s)
      cross apply (select replace(aAe.s,              'E', 'E') ) as aAeE (s)
      cross apply (select replace(aAeE.s,             'i', 'i') ) as aAeEi (s)
      cross apply (select replace(aAeEi.s,            'I', 'I') ) as aAeEiI (s)
      cross apply (select replace(aAeEiI.s,           'o', 'o') ) as aAeEiIo (s)
      cross apply (select replace(aAeEiIo.s,          'O', 'O') ) as aAeEiIoO (s)
      cross apply (select replace(aAeEiIoO.s,         'u', 'u') ) as aAeEiIoOu (s)
      cross apply (select replace(aAeEiIoOu.s,        'U', 'U') ) as aAeEiIoOuU (s)
      cross apply (select replace(aAeEiIoOuU.s,       'y', 'y') ) as aAeEiIoOuUy (s)
      cross apply (select replace(aAeEiIoOuUy.s,      'Y', 'Y') ) as aAeEiIoOuUyY (s)
      cross apply (select replace(aAeEiIoOuUyY.s,     'c', 'c') ) as aAeEiIoOuUyYc (s)
      cross apply (select replace(aAeEiIoOuUyYc.s,    'C', 'C') ) as aAeEiIoOuUyYcC (s)
      cross apply (select replace(aAeEiIoOuUyYcC.s,   'n', 'n') ) as aAeEiIoOuUyYcCn (s)
      cross apply (select replace(aAeEiIoOuUyYcCn.s,  'N', 'N') ) as aAeEiIoOuUyYcCnN (s)
    )
  , RemoveAccentsStep2 as
    (
    Select 
      Distinct
      s
    , NAS
    , UPPER(NAS) as NAUpperS
    , LOWER(NAS) as NALowerS
    From 
      RemoveAccentsStep1 
    )
  , RemoveAccentsStep3 as
    (
    Select 
      s
    , Upper(s) As UpperS
    , Lower(s) As LowerS
    , Upper(Left(s,1))+Lower(Stuff(s, 1, 1, '')) as FirstUpperOnly
    , NAS
    , NAUpperS
    , NALowerS
    , Left(NAUpperS,1)+Stuff(NAlowers, 1, 1, '') as NAFirstUpperOnly
    From 
      RemoveAccentsStep2
    )
 Select *
 From RemoveAccentsStep3 
 /*
 ;With SomeTable(someText) as (Select * From (values ('àâäèéêëöôòùûüÿçÀÂÄÈÉÊËÖÔÒÙÛÜŸÇ')) as T(s) )
 Select 
   R.s                  Collate latin1_general_ci_ai as s    
 , R.LowerS             Collate latin1_general_ci_ai as LowerS
 , R.UpperS             Collate latin1_general_ci_ai as UpperS
 , R.FirstUpperOnly     Collate latin1_general_ci_ai as FirstUpperOnly 
 , R.NAS                Collate latin1_general_ci_ai as NAS
 , R.NALowerS           Collate latin1_general_ci_ai as NALowerS
 , R.NAUpperS           Collate latin1_general_ci_ai as NAUpperS
 , R.NAFirstUpperOnly   Collate latin1_general_ci_ai as NAFirstUpperOnly
 from 
   SomeTable
   cross apply f$.ReShapeCaseAndAccents (SomeTable.SomeText) as R
*/
)
GO

---------------------------------------------------------------------------------------------------------
-- This function is useful to remove specific caracters from the end of a string
---------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RemoveAllTailingChar'
GO
--f$SignatureForCleanup
Create Function f$.RemoveAllTailingChar (@TailingChar nvarchar(5), @Str Nvarchar(max))
Returns @TxtSql table (s nvarchar(max) not null default '')
As
Begin

  Declare @NewStr nvarchar(max) = @Str

  While RIGHT(@NewStr, Len(@TailingChar)) = @TailingChar
  Begin
    Set @NewStr = LEFT(@NewStr, Len(@NewStr) - Len(@TailingChar))    
  End

  Insert Into @TxtSql Values(@NewStr)

  return
  /*
  Select * From f$.RemoveAllTailingChar('.', 'Fin..')
  Select * From f$.RemoveAllTailingChar(f$.Nl(), 'Ligne1' + f$.Nl())
  */
End
GO

---------------------------------------------------------------------------------------------------------
-- This function is useful to deduplicate duplicated sequence of char into a string
---------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.DedupSeqOfChars'
GO
--f$SignatureForCleanup
Create Function f$.DedupSeqOfChars (@Dup nvarchar(5), @Str Nvarchar(max))
Returns table
As
Return
(  
  With 
    PrmMultipleReplaces as 
    (
    Select NChar(0x25BA)+NChar(0x25C4) As StartEndPair
         , NChar(0x25C4)+NChar(0x25BA) as EndStartPair
         , @Str as StrWithDupCharSequence
         , @Dup as Dup
    ) 
  , Step1 as (Select *, replace(StrWithDupCharSequence, Dup, StartEndPair) as DupCharReplacedByStartEndPairs From PrmMultipleReplaces)
  , Step2 as (Select *, replace(DupCharReplacedByStartEndPairs, EndStartPair, '') as EndStartPairsRemoved From Step1)
  Select Replace(EndStartPairsRemoved, StartEndPair, Dup) as S
  From Step2
  /*
  Select * From f$.DedupSeqOfChars(',', 'a,,,b,c')
  Select * From f$.DedupSeqOfChars('zz', 'zzazzzzbzzc')
  Select * From f$.DedupSeqOfChars(' ', '| a    b  c  |')
  */
)
GO
---------------------------------------------------------------------------------------------------------
-- This function is useful cleanup from a string a set of char
---------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.CleanCharsFromStr'
GO
--f$SignatureForCleanup
Create Function f$.CleanCharsFromStr(@s nvarchar(max), @chars nvarchar(max), @replaceStr nvarchar(max))
Returns Table
as
Return
(
With 
  CleanStr as
  (
  Select @s as S, @chars as chars
  UNION ALL
  Select r.s, stuff(chars,1,1, '') as chars
  From
    CleanStr
    Cross Apply (select replace(s, left(chars,1), @replaceStr)) as r(s)
  Where len(chars)>0
  )
Select *
From 
  CleanStr
Where chars = ''
-- select * From f$.CleanCharsFromStr(' Test removal M'' of chars.?! "ok".', '!,;.?''"', ' ') as r1
)
go

---------------------------------------------------------------------------------------------------------
-- This function used with cross apply eliminate rows if item is not in list
-- To improve item parsing separator is replaced by | and a '|' is added as starting and end separator
---------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.InList'
GO
--f$SignatureForCleanup
Create Function f$.InList (@sep nvarchar(3), @item nvarchar(max), @List nvarchar(max))
returns table
as
return
(
  With 
   Prm as (select @item as Item, @Sep as Sep,  @List as List) 
 , completeSeperatedList As (select Sep, Sep+Item+Sep as NewItem, Sep+List+Sep as NewList From Prm)
 , ReportInfo as 
   (
   Select 
     ItemWithDedupSep.s as ItemWithDedupSep
   , 1 as Present
   , ListWithDedupSep.s as ListWithDedupSep
   , charindex (ItemWithDedupSep.s, ListWithDedupSep.s) as PosInList 
   From 
     completeSeperatedList
     CROSS APPLY f$.DedupSeqOfChars(Sep, NewItem) as ItemWithDedupSep
     CROSS APPLY f$.DedupSeqOfChars(Sep, NewList) as ListWithDedupSep
   )
  Select 1 as Present, ItemWithDedupSep, ListWithDedupSep, PosInList
  From ReportInfo
  Where PosInList > 0
  /*
  Select * From f$.InList (',', 'test', 'testto,testing,test')
  Select * From f$.InList (',', ',test', 'testto,testing,test')
  */
)
GO
Exec f$.DropObj 'f$.CleanXmlEscapes'
GO
---------------------------------------------------------------------------------------
-- When concatenating (through XML expression) query parts or data may produce
-- some XML escape char that we want back to their original values when reconverted to
-- nvarchar(max). This function is used by CleanXmlText
---------------------------------------------------------------------------------------
--f$SignatureForCleanup
Create Function f$.CleanXmlEscapes(@val nvarchar(max)) -- pour alléger écriture des concaténations
Returns Table
as
Return
(
Select r7.s
From
  f$.iReplace (@val, '&gt;', '>') as r0
  cross apply f$.iReplace (r0.s, '&lt;', '<') as r1
  cross apply f$.iReplace (r1.s, '&apos;', '''') as r2
  cross apply f$.iReplace (r2.s, '&quot;', '"') as r3
  cross apply f$.iReplace (r3.s, '&#x0D;', Nchar(13)) as r4
  cross apply f$.iReplace (r4.s, '&#x0A;', Nchar(10)) as r5
  cross apply f$.iReplace (r5.s, '&amp;', '&') as r6
  cross apply f$.iReplace (r6.s, '&#x20;', ' ') as r7
Where @val is not null
UNION 
Select @val Where @val is NULL
)
GO  
Exec f$.DropObj 'f$.CleanXmlText'
GO
---------------------------------------------------------------------------------------
-- When concatenating (through XML expression) query parts or data may produce
-- some XML escape char that we want back to their original values when reconverted to
-- nvarchar(max). This function is for f$.AdjConcat et f$.AdjConcatRS
-- It adds over CleanXmlEscapes remplacing null with empty string 
---------------------------------------------------------------------------------------
--f$SignatureForCleanup
Create Function f$.CleanXmlText(@val nvarchar(max)) -- pour alléger écriture des concaténations
Returns Table
as
Return (Select s From f$.CleanXmlEscapes(ISNULL(@val,'')))
GO  

---------------------------------------------------------------------------------------
-- When concatenating (through XML expression) query parts or data may produce
-- some XML escape char that we want back to their original values when reconverted to
-- nvarchar(max). 
---------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.AdjConcat'
GO
--f$SignatureForCleanup
Create Function f$.AdjConcat(@val nvarchar(max)) -- pour alléger écriture des concaténations
Returns Nvarchar(max) 
as
Begin
  Return
  (
  Select isnull(r0.s,'') as s
  From
    f$.CleanXmlText(@val) as r0
  )
  /*
  select '|'+f$.AdjConcat(NULL)+'|'
  select f$.AdjConcat((Select f$.CMax(', '+name+f$.Nl()) as [text()] from sys.Tables Order by name For XML PATH('')))
  select f$.AdjConcat((Select f$.CMax(f$.NL()+name) as [text()] from sys.Tables Order by name For XML PATH('')))
  */
End
GO
---------------------------------------------------------------------------------------
-- Same as f$.AdjConcat but with a parameter to replace initial separator by spaces
---------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.AdjConcatRS'
GO
--f$SignatureForCleanup
Create Function f$.AdjConcatRS(@sep nvarchar(max), @val nvarchar(max)) -- pour alléger écriture des concaténations
Returns Nvarchar(max) 
as
Begin
  Return
  (
  Select isnull(r1.s,'') as s
  From
    f$.CleanXmlText(@val) as r0
    cross apply (Select Charindex(@Sep, r0.s) as PosSep, Len(@sep) as CarToDelete) as P          
    cross apply (Select Case When posSep = 0 Then r0.s Else Stuff(r0.s, P.PosSep, P.CarToDelete, space(CarToDelete)) End as s) as r1 -- oter separateur d'élément si spécifié
  )
  /*
  select '|'+f$.AdjConcatRS(', ', NULL)+'|'
  select f$.AdjConcatRS(', ', (Select f$.CMax(', '+name+f$.Nl()) as [text()] from sys.Tables Order by name For XML PATH('')))
  select f$.AdjConcatRS('',   (Select f$.CMax(', '+name+f$.Nl()) as [text()] from sys.Tables Order by name For XML PATH('')))
  select f$.AdjConcatRS(f$.NL(),   (Select f$.CMax(f$.NL()+name) as [text()] from sys.Tables Order by name For XML PATH('')))
  */
End
GO
exec f$.dropObj 'f$.ReturnXMLValue'
GO
--f$SignatureForCleanup
Create Function f$.ReturnXMLValue (@Xml XML) -- see function ApplyConcatInfoFromXML to explain why this function has to be. this is a workaround of what appears to be a problem.
Returns XML
as
Begin
  declare @XmlToReturn XML
  Set @XmlToReturn = @Xml
  Return (@Xml)
End
GO
Exec f$.DropObj 'f$.ApplyConcatInfoFromXML'
GO
-- function to make easier to code data concat from multi-row
--f$SignatureForCleanup
Create Function f$.ApplyConcatInfoFromXML(@removeInitalSep int, @Separator nvarchar(max), @xml xml) -- makes concat easier to do
Returns Table
as
Return
(
  With 
    -- this function requires that the query that generate the @xml parameter uses for XML RAW, TYPE
    -- if the type parameter is forgotten, it may runs 30 times slower.
    -- To avoid this problem calling the function f$.ReturnXMLValue over the @xml parameter, solve this problem.
    MakeXMLVar as (Select f$.ReturnXMLValue(@xml) as toXmlToPRocess)
  , SplitXmlByRow as
    (
    SELECT 
      row.query('.') as EachRow
    FROM 
      MakeXMLVar M
      CROSS APPLY 
      M.toXmlToPRocess.nodes('/row') d(row)
    )
  , XMLtoRelational as
    (
    Select 
      d.row.value('(/row/@*[position()=1])[1]','nvarchar(max)') AS toConcat
    , d.row.value('(/row/@*[position()=2])[1]','nvarchar(max)') AS SortData
    From 
      SplitXmlByRow
      Cross apply EachRow.nodes('/row') as d(row)
    )
  , ResultSwitch (res) as
    (
    Select 
      f$.AdjConcatRS
      ( isnull(@Separator,'') 
      , (
        Select f$.CMax(isnull(@Separator,'') +toConcat) as [text()]
        From 
          XMLtoRelational
        Order By SortData
        For XML Path('')
        )
      ) 
    Where @removeInitalSep = 1
    UNION ALL
    Select 
      f$.AdjConcat
      ( (
        Select f$.CMax(isnull(@Separator,'') +toConcat) as [text()]
        From 
          XMLtoRelational
        Order By SortData
        For XML Path('')
        )
      ) 
    Where @removeInitalSep = 0
    )
  Select res
  From
    ResultSwitch
  /*
 with someXml (Xml) as (Select (select name+nchar(10)+nchar(13) as d from sys.columns order by name for xml raw, type) )
   Select res from someXml cross apply f$.ApplyConcatInfoFromXML(0, ' ,', xml) union all
   Select res from someXml cross apply f$.ApplyConcatInfoFromXML(1, ' ,', xml) union all
   Select res from someXml cross apply f$.ApplyConcatInfoFromXML(0, '', xml) union all
   Select res from someXml cross apply f$.ApplyConcatInfoFromXML(1, '', xml) 
  */
)
GO
Exec f$.DropObj 'f$.ConcatInfoFromXML'
GO
--f$SignatureForCleanup
Create Function f$.ConcatInfoFromXML(@removeInitalSep int, @Separator nvarchar(max), @x xml) -- the scalar version of the previous function
Returns nvarchar(max)
as
Begin
  declare @res nvarchar(max);
  Select @res = res
  From f$.ApplyConcatInfoFromXML(@removeInitalSep, @Separator, @x)
  return(@res)
  /*
 with someXml (Xml) as (Select (select name+nchar(10)+nchar(13) as d, column_id from sys.columns where object_id = object_id ('f$.RealScriptToRun') for xml raw, type) )
   Select f$.ConcatInfoFromXML(0, ' ,', xml) from someXml union all
   Select f$.ConcatInfoFromXML(1, ' ,', xml) from someXml union all
   Select f$.ConcatInfoFromXML(0, '', xml) from someXml union all
   Select f$.ConcatInfoFromXML(1, '', xml) from someXml 
  */
End
GO
--
-- This function does the job of finding the nth attribute in a xml row whose the single element is "row"
-- It receive the maximum number of element of the row and avoid search for attribute number greater
-- than the real number of attributes. Used only by ReplaceTagsMatchingXMLAttributesNamesByTheirValue
--
Exec f$.DropObj 'F$.ReplaceNthXMLAttributeByItsValue'
GO
/*===VersionBeforeSQL2016===--f$SignatureForCleanup
Create Function F$.ReplaceNthXMLAttributeByItsValue (@Template nvarchar(max), @AttributePos Int, @NbOfAttributes Int, @Row XML)
Returns Table
as
Return
(
With 
  Prm as (select @Template as Template, @AttributePos as AttributePos, @NbOfAttributes as NbOfAttributes, @Row as XmlDoc)
, Result as
  (
  select template as s From Prm Where AttributePos > NbOfAttributes -- nothing to change
  UNION ALL
  Select r0.s
  From 
    Prm
    Cross apply XmlDoc.nodes('/row') as d(row)
    OUTER APPLY f$.iReplace
                   ( template
                   , '#'+d.row.value('local-name((/row/@*[position()=sql:column("Prm.AttributePos")])[1])', 'NVARCHAR(512)')+'#'
                   , d.row.value('(/row/@*[position()=sql:column("Prm.AttributePos")])[1]','nvarchar(max)')
                   )  as r0
  Where AttributePos <= NbOfAttributes
    And d.row.value('(/row/@*[position()=sql:column("Prm.AttributePos")])[1]','nvarchar(max)') IS NOT NULL
    And d.row.value('local-name((/row/@*[position()=sql:column("Prm.AttributePos")])[1])', 'NVARCHAR(30)') IS NOT NULL
  )
  Select s as tmpl
  From Result
)
===VersionBeforeSQL2016===*/

/*===VersionSQL2016===--f$SignatureForCleanup
Create Function F$.ReplaceNthXMLAttributeByItsValue (@Template nvarchar(max), @AttributePos Int, @NbOfAttributes Int, @Row XML)
Returns Table
as
Return
(
With 
  Prm as (select @Template as Template, @AttributePos as AttributePos, @NbOfAttributes as NbOfAttributes, @Row as XmlDoc)
, Result as
  (
  select template as s From Prm Where AttributePos > NbOfAttributes -- nothing to change
  UNION ALL
  Select r0.s
  From 
    Prm
    Cross apply XmlDoc.nodes('/row') as d(row)
    -- SQL2016, can't use f$.ireplace for this Outer apply, but this form is problematic for some previous versions like SQL2012
    -- The calling function f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue compile forever
    -- so the workaround formulation for SQL2016 is using a the replace function in the outer apply
    OUTER APPLY 
    ( 
      select 
        replace
        (  template
        , '#'+d.row.value('local-name((/row/@*[position()=sql:column("Prm.AttributePos")])[1])', 'NVARCHAR(512)')+'#'
        , d.row.value('(/row/@*[position()=sql:column("Prm.AttributePos")])[1]','nvarchar(max)')
        )
    )  as r0(s)
  Where AttributePos <= NbOfAttributes
    And d.row.value('(/row/@*[position()=sql:column("Prm.AttributePos")])[1]','nvarchar(max)') IS NOT NULL
    And d.row.value('local-name((/row/@*[position()=sql:column("Prm.AttributePos")])[1])', 'NVARCHAR(30)') IS NOT NULL
  )
  Select s as tmpl
  From Result
)
===VersionSQL2016===*/
Insert into f$.ScriptToRun (sql, seq)
select B.BatchComment, 1
From 
  f$.SQLVersionInfo() as V
  cross apply (Select Case When V.ProductMajorVersion >= 13 Then '===VersionSql2016===' Else '===VersionBeforeSQL2016===' End) as CodeVersion(sql)
  cross apply f$.GetCommentFromBatch(CodeVersion.sql) as B
Exec f$.RunScript  @printOnly = 0, @silent=1
GO
Exec f$.DropObj 'F$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue'
GO
--f$SignatureForCleanup
Create Function F$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue (@Template nvarchar(max), @XmlToReplace XML)
Returns @Sql Table (finalReplace nvarchar(max))
as
Begin
  -- could be written fully as an inline function, but it is lighter to use this way
  -- cardinality estimate get wierd for nothing (in sql2012)
  Declare @InfosForReplaces Table (NbAtt int, attSeq int, EachRow XML, template nvarchar(max));
  With 
    --Prm as -- for test
    --(
    --select 
    --  'Select #FullTbName#.#cn# From #FullTbName#' as template
    --, (
    --  select 
    --    Cols.FullTbName
    --  , Cols.cn 
    --  From f$.ColInfo(null, null) as Cols Order By Cols.FullTbName, Cols.cn for Xml raw, type
    --  ) as XmlToReplace
    --)
    Prm as (select @Template As Template, @XmlToReplace as XmlToReplace)
  , MakeXMLVar as (Select f$.ReturnXMLValue(XmlToReplace) as toXmlToPRocess, template from Prm)
  , SplitXmlByRow as
    (
    SELECT 
      row.query('.') as EachRow
    , template
    FROM 
      MakeXMLVar M
      CROSS APPLY 
      M.toXmlToPRocess.nodes('/row') d(row)
    )
    --Select * From SplitXmlByRow
  , XmlRowsAndNumberOfAttributesByRow as
    (
    Select 
      EachRow.value('count(/row/@*)','INT') as NbAtt
    , Row_Number() Over (Order by Convert(nvarchar(max), EachRow)) as attSeq
    , EachRow
    , template
    from SplitXmlByRow
    )
  Insert into @InfosForReplaces
  Select * from XmlRowsAndNumberOfAttributesByRow

  ;with
    TemplateReplaces as
    (
    Select 
      attSeq
    , NbAtt
    , EachRow
    , template
    , r29.tmpl as FinalReplace 
    From 
      @InfosForReplaces
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(template, 01, nbAtt, EachRow) as r01
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r01.tmpl, 02, nbAtt, EachRow) as r02
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r02.tmpl, 03, nbAtt, EachRow) as r03
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r03.tmpl, 04, nbAtt, EachRow) as r04
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r04.tmpl, 05, nbAtt, EachRow) as r05
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r05.tmpl, 06, nbAtt, EachRow) as r06
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r06.tmpl, 07, nbAtt, EachRow) as r07
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r07.tmpl, 08, nbAtt, EachRow) as r08
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r08.tmpl, 09, nbAtt, EachRow) as r09
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r09.tmpl, 10, nbAtt, EachRow) as r10
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r10.tmpl, 11, nbAtt, EachRow) as r11
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r11.tmpl, 12, nbAtt, EachRow) as r12
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r12.tmpl, 13, nbAtt, EachRow) as r13
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r13.tmpl, 14, nbAtt, EachRow) as r14
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r14.tmpl, 15, nbAtt, EachRow) as r15
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r15.tmpl, 16, nbAtt, EachRow) as r16
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r16.tmpl, 17, nbAtt, EachRow) as r17
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r17.tmpl, 18, nbAtt, EachRow) as r18
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r18.tmpl, 19, nbAtt, EachRow) as r19
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r19.tmpl, 20, nbAtt, EachRow) as r20
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r20.tmpl, 21, nbAtt, EachRow) as r21
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r21.tmpl, 22, nbAtt, EachRow) as r22
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r22.tmpl, 23, nbAtt, EachRow) as r23
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r23.tmpl, 24, nbAtt, EachRow) as r24
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r24.tmpl, 25, nbAtt, EachRow) as r25
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r25.tmpl, 26, nbAtt, EachRow) as r26
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r26.tmpl, 27, nbAtt, EachRow) as r27
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r27.tmpl, 28, nbAtt, EachRow) as r28
      Cross Apply F$.ReplaceNthXMLAttributeByItsValue(r28.tmpl, 29, nbAtt, EachRow) as r29
    )
  Insert into @Sql
  select FinalReplace
  From 
    TemplateReplaces
  Return
  /* some test
  With 
    AllTbs as
    (
    Select
      '
      Create Table #Tb#
      (
      #Cols#    )
      TEXTIMAGE_ON 
      ' as CreateTb
    , F$.FullObjName(object_id) as Tb 
    From Sys.tables
    )
  , Tb as 
    (
    Select  
      *
    , (select Tb For XML RAW, TYPE) as TbListInXml
    , (
      Select Cols.ColDef+nchar(10) as cols -- important to name it this way so a replace over #Cols# will be performed
      From F$.ColInfo(Tb, NULL) as Cols Order by cols.ColOrd FOR XML RAW, TYPE
      ) as ColsTbInXml
    From
      AllTbs
    )
  , ReplTbNameAndPrepReplBlocCols as 
    (
    Select MainSyntaxTb.FinalReplace, (Select ColsGroup.res as Cols For XML Raw, type) as BlocColsInXml
    From 
      Tb as T
      Cross Apply F$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(T.CreateTb, T.TbListInXml) as MainSyntaxTb
      cross apply f$.ApplyConcatInfoFromXML(1, '    , ', T.ColsTbInXml) as ColsGroup
    )
  Select r0.FinalReplace, RT.BlocColsInXml
  From 
    ReplTbNameAndPrepReplBlocCols  RT
    Cross Apply F$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(RT.FinalReplace, RT.BlocColsInXml) as r0
  */
End
GO

------------------------------------------------------------------------------------------------
-- Apply SQL set operation on list items and returns list item
-- Ex:   Select f$.ApplySetOperOnLists ('Intersect', ',',  'a, b, c', 'b, c, d') --> ('b, c')
------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ApplySetOperOnLists'
GO
--f$SignatureForCleanup
CREATE function f$.ApplySetOperOnLists 
(
  @SetOper as nvarchar(10) -- Distinct, union, intersect, except
, @sep nchar(1) -- list separator
, @list1 nvarchar(max) -- first list
, @list2 nvarchar(max) = null -- second list)
)
returns nvarchar(max)
as
Begin
  declare @list as nvarchar(max)
  If @setOper = 'distinct' And isnull(@List2, '') = ''  Set @list2 = @list1

  ;With -- apply set operation and try to keep original order in lists
    AllTogetherWithInfo As
    (
    Select 'List1' as ListSource, seq, item From f$.SplitList (@sep, @list1)
    union all 
    Select 'List2' as ListSource, seq, item From f$.SplitList (@sep, @list2)
    )
  , TogetherWithSeqInfo As
    (
    Select 
      *
    , Row_number() Over (Partition By Item Order By ListSource, seq) as ReptitiveItemSeqByListAndOrderInList
    , Max(ListSource) Over (Partition By Item) as MaxListSourceForIdenticalItems
    , Min(ListSource) Over (Partition By Item) as MinListSourceForIdenticalItems
    From AllTogetherWithInfo   
    )
  , Distincts As
    (
    Select *
    From TogetherWithSeqInfo
    Where ReptitiveItemSeqByListAndOrderInList = 1
    )
  , Intersects As
    (
    Select *
    From TogetherWithSeqInfo
    Where ListSource = 'List1' 
      And MaxListSourceForIdenticalItems <> MinListSourceForIdenticalItems
      And ReptitiveItemSeqByListAndOrderInList = 1
    )
  , Excepts As
    (
    Select *
    From TogetherWithSeqInfo
    Where ReptitiveItemSeqByListAndOrderInList = 1
      And MaxListSourceForIdenticalItems = MinListSourceForIdenticalItems
      And ListSource = 'List1'
    )
  , ChooseFromProperSetOper as
    (
    Select * from Intersects Where @SetOper = 'Intersect' union all
    Select * from Distincts Where @SetOper in ('Distinct', 'Union') union all
    Select * from Excepts Where @SetOper = 'Except' 
    )
  Select 
  @list =
    f$.AdjConcatRS
    (
      @Sep
    , (
      Select f$.CMax(@Sep + item) AS [text()] 
      From 
        ChooseFromProperSetOper 
      Where item is Not NULL
      Order by ListSource, Seq
      For XML PATH ('')
      )
    ) 
  Return(@List)

End --ApplySetOperOnLists
GO
-- -------------------------------------------------------------------------------------------------------------
-- Function return full object name of a specific object_id.  Very useful to get fully qualified 
-- object name from an object_id or from object_id function.
-- -------------------------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.FullObjName'
GO
--f$SignatureForCleanup
create function f$.FullObjName
( 
@object_id Int
)
Returns sysname
as
Begin
  Return ('['+object_schema_name(@Object_id)+'].[' +object_name(@Object_Id)+']')
End
-- Select f$.FullObjName (object_id('f$.FullObjName'))  
GO
-- -------------------------------------------------------------------------------------------------------------
-- Function return full object name of a specific object_id.  Very useful to get fully qualified 
-- object name from an object_id or from object_id function.  It does it for a the specified Db
-- -------------------------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.FullObjNameFromDb'
GO
--f$SignatureForCleanup
create function f$.FullObjNameFromDb
( 
  @object_id Int
, @dbName sysname
)
Returns sysname
as
Begin
  Return ('['+object_schema_name(@Object_id, Db_id(@DbName))+'].[' +object_name(@Object_Id, Db_id(@DbName))+']')
End
 --If OBJECT_ID('tempdb.dbo.tmp') is not null drop table tempdb.dbo.tmp
 --create table tempdb.dbo.tmp(i int); 
 --Select f$.FullObjNameFromDb (object_id('tempdb.dbo.tmp'), 'Tempdb')
 --drop table tempdb.dbo.tmp
GO
-- -------------------------------------------------------------------------------------------------------------
-- Function that get rid of annoying quotes in fully qualified object names
-- -------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.UnQuoteName'
GO
--f$SignatureForCleanup
Create Function f$.UnQuoteName(@val nvarchar(max)) -- pour alléger écriture des concaténations
Returns Nvarchar(max) 
as
Begin
  Return
  (
  Select r1.s
  From          
    f$.iReplace (@val, '[', '') as r0
    cross apply f$.iReplace (r0.s, ']', '') as r1
  )
End
GO
-- -------------------------------------------------------------------------------------------------------------
-- Function returns ON of OFF for given bit values 1 and 0
-- -------------------------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.OnOff'
GO
--f$SignatureForCleanup
create function f$.OnOff (@ZeroOrOne as Int) 
Returns nvarchar(3)
as
begin
  Return (case When @ZeroOrOne = 1 Then 'ON' Else 'OFF' End)
End
GO
-- -----------------------------------------------------------------------------------------------------------------------------
-- This function generate script to build an a function that return a constant value.  The constat value has the same 
-- value as its name other specified.  From an optimizer standpoint it is replaced by its constant value in the query that
-- use the "constant" "function"
-- -----------------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.BuildConstFctScript'
GO
--f$SignatureForCleanup
Create Function f$.BuildConstFctScript (@ConstSchema sysname, @ConstNamesAndValues nvarchar(max), @QuotingType Nvarchar(30)=NULL) 
Returns Table
as
Return
(
/*---DefSchemaTemplate---Exec ('Create Schema [#ConstSchema#] Authorization Dbo')---DefSchemaTemplate---*/
/*---DefinitionTemplate---#SignatureForCleanup#Create Function [#ConstSchema#].[#ConstName#]()  Returns Sysname as Begin Return (#StartQuote##ConstValue##EndQuote#) End---DefinitionTemplate---*/
/*---DropTemplate---Exec f$.DropObj '[#ConstSchema#].[#ConstName#]'---DropTemplate---*/

  --With PrmToCols (ConstSchema, ConstNamesAndValues, QuotingType) as (Select 'f$', 'EnumTest|1, ZZ|2', 'None')
  --With PrmToCols (ConstSchema, ConstNamesAndValues, QuotingType) as (Select 'f$', 'EnumTest|1, ZZ|2', 'NULL')
  --With PrmToCols (ConstSchema, ConstNamesAndValues, QuotingType) as (Select 'f$', 'enum1|1, emum2|2', 'HexString')
  --With PrmToCols (ConstSchema, ConstNamesAndValues, QuotingType) as (Select 'f$', 'enum1|1, emum2|2', 'HexString')
  --With PrmToCols (ConstSchema, ConstNamesAndValues, QuotingType) as (Select 'test', 'test|Test.toto', NULL)
  --With PrmToCols (ConstSchema, ConstNamesAndValues, QuotingType) as (Select 'f$', 'ACHAT,AG', NULL)
  With PrmToCols (ConstSchema, ConstNamesAndValues, QuotingType) as (Select @ConstSchema, @ConstNamesAndValues, @QuotingType)
, Prm as 
  (
  Select 
    P.*
  , Case 
      When ISNULL(P.QuotingType, 'String') = 'String' Then '''' 
      When P.QuotingType = 'hexString' Then '0x' 
      Else ''
    End as StartQuote
  , Case 
      When ISNULL(P.QuotingType, 'String') = 'String' Then '''' 
      Else ''
    End as EndQuote
  , DefSchemaTemplate.CommentContent  DefSchemaTemplate
  , DefinitionTemplate.CommentContent as DefinitionTemplate
  , DropTemplate.CommentContent as DropTemplate
  From 
    PrmToCols as P 
    Cross Apply (Select Object_id('f$.BuildConstFctScript')) T(MySelf)
    Cross Apply f$.GetCommentFromSqlObj(MySelf, '---DefSchemaTemplate---') as DefSchemaTemplate
    cross apply f$.GetCommentFromSqlObj(MySelf, '---DefinitionTemplate---') as DefinitionTemplate
    cross apply f$.GetCommentFromSqlObj(MySelf, '---DropTemplate---') as DropTemplate
  )
  --Select * From Prm
, TemplateToReplaceConst as 
  (
  Select 
    DefSchemaTemplate
  , DefinitionTemplate
  , DropTemplate
  , ConstSchema
  , PL.item1 as ConstName
  , PL.Seq as ConstSeq
  , ISNULL(PL.item2, PL.item1) as ConstValue
  , (  
    Select
      ConstSchema
    , Case When ConstSchema = 'f$' Then '--f$SignatureForCleanup'+f$.NL() Else '' End as SignatureForCleanup
    , PL.item1 as ConstName
    , ISNULL(PL.item2, PL.item1) as ConstValue
    , PL.Seq as ConstSeq
    , Prm.StartQuote
    , Prm.EndQuote
    For XML Raw, Type
    ) as ReplaceFromTheseAttr
  From
    Prm  
    cross apply f$.SplitPairsList (',|', Prm.ConstNamesAndValues) as PL
  )
  --Select * from TemplateToReplaceConst
, SyntaxElements as 
  (
  Select 
    T.*
  , CreateSchema.finalReplace as CreateSchema
  , ObjectDef.finalReplace as ObjectDef
  , DropAction.finalReplace as DropAction
  , OBJECT_DEFINITION(OBJECT_ID(T.ConstSchema+'.'+T.ConstName)) as ExistingObjDef
  From 
    TemplateToReplaceConst T
    CROSS APPLY f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue (T.DefSchemaTemplate, T.ReplaceFromTheseAttr) as CreateSchema
    CROSS APPLY f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue (T.DefinitionTemplate, T.ReplaceFromTheseAttr) as ObjectDef
    CROSS APPLY f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue (T.DropTemplate, T.ReplaceFromTheseAttr) as DropAction
  )      
  -- TOP 1 because there is only one same schema by call for many constants
  Select Top 1 CreateSchema as Sql, ConstSeq, ExistingObjDef, ObjectDef  
  From SyntaxElements
  Where SCHEMA_ID(ConstSchema) IS NULL
  UNION ALL
  -- drop object if it is not null and different then new object def
  Select DropAction, 1000 + ConstSeq, ExistingObjDef, ObjectDef
  From SyntaxElements 
  Where ExistingObjDef IS NOT NULL And ExistingObjDef <> ObjectDef
  UNION ALL
  -- create object if it is null Or different then new object def
  Select ObjectDef, 10000 + ConstSeq, ExistingObjDef, ObjectDef 
  From 
    SyntaxElements
  Where ExistingObjDef IS NULL Or ExistingObjDef <> ObjectDef
/*
Exec f$.DropObj '[f$].[EnumTest]'
Exec f$.DropObj '[f$].[ZZ]'
*go* -- [f$].[EnumTest]() defined this way will make generate a drop function because new definition is different
Exec('Create Function [f$].[EnumTest]()  returns sysname as Begin Return (''EnumTest'') End')
*go* -- [f$].[ZZ]() defined this way will make generate no drp no create because function is defined the same
Exec('Create Function [f$].[ZZ]()  Returns Sysname as Begin Return (2) End')
*go*
select OBJECT_DEFINITION(OBJECT_ID('f$'+'.'+'EnumTest'))+'|'
Select *, case when ExistingObjDef <> ObjectDef Then 1 Else 0 End From f$.BuildConstFctScript ('f$', 'EnumTest|1, ZZ|2', 'None')
print '================================= test begin here ================================='
Insert Into f$.ScriptToRun (sql, Seq)
Select Sql, ConstSeq From f$.BuildConstFctScript ('f$', 'EnumTest|1, ZZ|2', 'None')
Exec f$.RunScript @PrintOnly=0
print '================================= test end here ================================='
*go* -- test cleanup
Exec f$.DropObj '[f$].[EnumTest]'
Exec f$.DropObj '[f$].[ZZ]'
*/
)
GO
Exec f$.DropObj 'f$.PrintScript'
GO
--f$SignatureForCleanup
Create Proc f$.PrintScript As Exec f$.RunScript @printonly=1
GO
Exec f$.DropObj 'f$.MakeConstFcts'
GO
--f$SignatureForCleanup
Create Proc f$.MakeConstFcts @ConstSchema sysname, @ConstNamesAndValues nvarchar(max), @QuotingType Nvarchar(30)=NULL
as
Begin
  Insert Into f$.ScriptToRun (Sql, seq)
  Select B.sql, ConstSeq From f$.BuildConstFctScript (@ConstSchema, @ConstNamesAndValues, @QuotingType) B
  exec f$.RunScript @PrintOnly=0
  /*
-- Tests different code gen depending of schema/object presence and identical of different object definition
exec f$.dropObj 'test.test'
If schema_id('test') IS NOT NULL Exec('Drop schema test');
Print '--------create schema because is doesn''t exist and create object'
Exec f$.MakeConstFcts @ConstSchema='test', @ConstNamesAndValues='test|Test.toto'
Print 'Function value:'+test.test()
Print '--------Gen no create schema, it is there. Drop Object because it is different than existing, create object'
Exec ('Alter function test.test() returns Int as Begin return 1 End')
Exec f$.MakeConstFcts @ConstSchema='test', @ConstNamesAndValues='test|Test.toto'
Print 'Function value:'+test.test()
Print '--------Gen Nothing since function is the same and schema exists'
Exec f$.MakeConstFcts @ConstSchema='test', @ConstNamesAndValues='test|Test.toto'
Print 'Function value:'+test.test()
Print '--------Test cleanup'
exec f$.dropObj 'test.test'
If schema_id('test') IS NOT NULL Exec('Drop schema test');

Exec f$.MakeConstFcts @ConstSchema='Test', @ConstNamesAndValues='ACHAT,AG'
Print 'Function values: Test.Achat='+test.Achat()+' Test.Ag='+test.Ag()
Print '--------Test cleanup'
exec f$.dropObj 'test.Achat';exec f$.dropObj 'test.Ag'
drop schema test

Print 'Function created with signatures: f$.Achat=1 f$.Ag=2'
Exec f$.MakeConstFcts @ConstSchema='f$', @ConstNamesAndValues='ACHAT|1,AG|2', @quotingType='none'
Print 'Function values: f$.Achat='+f$.Achat()+' f$.Ag='+f$.Ag()
Print '--------Test cleanup'
exec f$.dropObj 'f$.Achat';exec f$.dropObj 'f$.Ag'

Exec f$.MakeConstFcts @ConstSchema='Consts', @ConstNamesAndValues='ValidationMsgs|Test.ValidationMsgs'
Print 'Function values: Consts.ValidationMsgs()='+Consts.ValidationMsgs()
exec f$.dropObj 'Consts.ValidationMsgs'
Drop Schema Consts

  */
End
GO
-- -----------------------------------------------------------------------------------------------------------------------------
-- This function generate script to build an enum group.  Enums values are presented as a pair list
-- like 'enum1|value1, enum2|value2, enum3|value3'. Missing values are replaced the enum name.
-- -----------------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.MakeEnumsScriptForEnumSet'
GO
--f$SignatureForCleanup
Create Function f$.MakeEnumsScriptForEnumSet (@enumSchema sysname, @EnumSet sysname, @EnumValues Nvarchar(max), @QuotingType Nvarchar(30), @pairListSep Nvarchar(2))
Returns Table
as
Return
(
With 
  Prm as (Select @EnumSchema as EnumSchema,  @EnumSet as EnumSet, @EnumValues As EnumValues, @QuotingType as QuotingType, @pairListSep as PairListSep)
, PrepPrm as 
  (
  Select 
    EnumSchema, EnumSet, EnumValues
  , Case 
      When ISNULL(QuotingType, 'String') = 'String' Then 'Convert(nvarchar(max), "' 
      When QuotingType = 'hexString' Then 'Convert(varbinary(max), 0x' 
      Else ''
    End as StartQuote
  , Case 
      When ISNULL(QuotingType, 'String') = 'String' Then '")' 
      When QuotingType = 'hexString' Then ')' 
      Else ''
    End as EndQuote
  , PairListSep
  From 
    Prm
  ) 
, EnumTemplate as
  (
  Select 
    1 as Seq
  , 'If SCHEMA_ID("#enumSchema#") IS NULL Exec("Create schema #enumSchema# Authorization Dbo")' as Sql
  UNION ALL
  Select 
    2 as Seq
  , 'Exec  f$.DropObj "#enumSchema#.#EnumSet#"' as Sql
  UNION ALL
  Select
    3 as Seq
  ,'
  Create Function #EnumSchema#.#EnumSet# ()
  Returns Table
  as
  Return
  (
  With 
    #EnumSet#CTE as 
    (
    Select #Enums#
    ) 
  Select * From #EnumSet#CTE
  )
  '
  )
, TbEnumName as 
  (
  Select 
    PP.EnumSchema
  , PP.EnumSet
  , f$.AdjConcatRS
    (  ', '
    ,  (
       Select 
         f$.CMax(', '+StartQuote+ISNULL(L.item2, L.Item1)+EndQuote+' As '+ ISNULL(L.item1, 'E'+Convert(nvarchar, L.Seq))) as [text()]
       From 
         f$.SplitPairsList (ISNULL(pairListSep, ',|'), PP.EnumValues) as L
       Order By L.Seq
       For XML Path('')
       )
    ) as Enums
  From PrepPrm as PP
  )
Select r2.s as Sql, seq
From 
  EnumTemplate as Et
  CROSS JOIN TbEnumName as Ev
  CROSS APPLY f$.iReplace(Et.Sql, '#EnumSet#', Ev.EnumSet) as r0
  CROSS APPLY f$.iReplace(r0.s, '#enumSchema#', Ev.EnumSchema) as r1
  CROSS APPLY f$.iQReplace(r1.s, '#Enums#', Ev.Enums) as r2
)
GO
Exec f$.DropObj 'f$.MakeEnumSet'
GO
--f$SignatureForCleanup
Create Proc f$.MakeEnumSet @enumSchema sysname, @EnumSet sysname, @EnumValues Nvarchar(max), @QuotingType Nvarchar(30)=NULL, @PairListSep Nvarchar(2)=NULL
as
Begin
  Set Nocount On
  Insert Into f$.ScriptToRun (Sql, seq)
  Select B.sql, seq From f$.MakeEnumsScriptForEnumSet (@enumSchema, @EnumSet, @EnumValues, @QuotingType, @pairListSep) B
  exec f$.RunScript @PrintOnly=0
  /*
Exec f$.MakeEnumSet @EnumSchema='f$', @EnumSet='GRICSAPP', @EnumValues='ACHAT,AG,CDV,DOFIN,EDUGROUPE,GEOBUS,GPI,HELIOS,JADE,PAIE,REGARD,SRI', @QuotingType='String'
Exec f$.MakeEnumSet @EnumSchema='f$', @EnumSet='GRICSAPP', @EnumValues='ACHAT|1,AG|2,CDV|3,DOFIN|4,EDUGROUPE|5,GEOBUS|6,GPI|7,HELIOS|8,JADE|9,PAIE|10,REGARD|11,SRI|12', @QuotingType='None'
Exec f$.MakeEnumSet @EnumSchema='f$', @EnumSet='GRICSAPP', @EnumValues='ACHAT|1,AG|2,CDV|3,DOFIN|4,EDUGROUPE|5,GEOBUS|6,GPI|7,HELIOS|8,JADE|9,PAIE|10,REGARD|11,SRI|12', @QuotingType='HexString'
  */
End
GO
exec f$.DropObj 'f$.GenKillDbConnections'
GO
--f$SignatureForCleanup
Create Function f$.GenKillDbConnections (@dbList nvarchar(max))
returns table 
as
return
(
With 
  TemplateKill as 
  (
  Select
    '
    use master 
    alter database [#DbName#] set offline with rollback immediate
    alter database [#DbName#] set online
    ' as Sql
  , Case ISNULL(@dbList, '') When '' Then DB_NAME() Else @dbList End As dbList
  )
Select 
  r0.s, L.seq as Seq
From 
  TemplateKill
  CROSS APPLY f$.SplitList(',', dbList) as L
  CROSS APPLY f$.iReplace (TemplateKill.sql, '#DbName#', L.item) as r0
Where DB_ID(L.item) IS NOT NULL
)
GO
exec f$.DropObj 'f$.KillDbConnections'
GO
--f$SignatureForCleanup
Create Procedure f$.KillDbConnections @dbList sysname = NULL
as
Begin
  Set Nocount On

  Insert into f$.ScriptToRun (sql, seq) 
  Select K.s, K.Seq
  From 
    f$.GenKillDbConnections (@dbList) as K
  Order By K.Seq
  Exec f$.RunScript @printOnly = 0
End
GO
-- -------------------------------------------------------------------------------------------------------------
-- Function that build data type expression that fits column metadata from sys.columns
-- used by f$.ColInfo function
-- -------------------------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.GetDataTypeExpressionElements'
GO
--f$SignatureForCleanup
create function f$.GetDataTypeExpressionElements 
( 
  @TypeId Int
, @SysTypeId Int
, @MaxLen Int
, @NumPrec Int
, @NumScale Int
, @isComputed Int
, @isXmlDocument Int
, @XmlSchemaName sysname
)
Returns Table
as
Return
(
With 
  Prms as 
  (
  Select *
  From 
    Sys.Types 
    CROSS APPLY (Select MaxLen=@MaxLen, NumPrec=@NumPrec, NumScale=@NumScale) as p1
    CROSS APPLY (Select isComputed=@isComputed, isXmlDocument=@isXmlDocument, XmlSchemaName=@XmlSchemaName) as p2
    CROSS APPLY (Select UserType=Type_name(user_type_id)) as vUserType
    CROSS APPLY (Select SystemType=Type_name(system_type_id)) as vSystemType
    CROSS APPLY (Select SchemaTypeSrc=Schema_name(Schema_id)+'.') as vSchemaTypeSrc
    CROSS APPLY (Select SchemaTypeName=IIF(SchemaTypeSrc='sys.', '', SchemaTypeSrc)) as vSchemaTypeName
  Where user_type_id = @typeId
  )
, TypeBuildInfo as
  (
  Select *
  From
    Prms
    CROSS APPLY (Select Quote='''', UQuote='N''', BinPrefix='0x', noQuote='') as vQuoting
    Cross Apply
    (
    Values
      ('varchar', '(#maxLen#)', Quote, Quote                  )
    , ('nvarchar', '(#maxLen#)', UQuote, Quote                )
    , ('char', '(#maxLen#)', Quote, Quote                     )
    , ('nchar', '(#maxLen#)', UQuote, Quote                   )
    , ('varbinary', '(#maxLen#)', BinPrefix, noQuote          )
    , ('binary', '(#maxLen#)', BinPrefix, noQuote             )
    , ('numeric', '(#NumPrec#, #NumScale#)', noQuote, noQuote )
    , ('decimal', '(#NumPrec#, #NumScale#)', noQuote, noQuote )
    , ('time', '(#NumScale#)', Quote, Quote                   )
    , ('datetime', '', Quote, Quote                           )
    , ('datetime2', '(#NumScale#)', Quote, Quote              )
    , ('datetimeoffset', '(#NumScale#)', Quote, Quote         )
    , ('xml', '#XmlSpec#', Quote, Quote                       )
    ) TypeNameAndPrm (MatchType, SpecTags, startQuote, EndQuote) 
  Where Prms.isComputed=0 -- not a computed column
    And TypeNameAndPrm.MatchType = Prms.UserType -- not a user defined type
  )
Select 
  Prms.UserType
, Prms.SystemType
, ComputeTypDefElements.*
, TypeSpecSel.*
, Spec
, TypeSpec
From 
  Prms

  CROSS APPLY
  (
  Select *
  From 
                (Select OneCharLen=IIF(SystemType Like 'N[VC]%',2,1)) as vOneCharLen
    CROSS APPLY (Select charMaxLen=IIF(MaxLen = -1, 2147483647, MaxLen/OneCharLen)) as vCharMaxLen
    CROSS APPLY (Select SMaxLen=IIF(MaxLen = -1, 'Max', convert(nvarchar, CharMaxLen))) as vSMaxLen
    CROSS APPLY (Select SnumPrec=convert(nvarchar, numPrec)) as vSnumPrec
    CROSS APPLY (Select SnumScale=convert(nvarchar, NumScale)) as vSnumScale
    CROSS APPLY (Select XmlSchemaDocType=IIF(isXmlDocument=1, 'Document', 'Content')) as vXmlSchemaDocType
    CROSS APPLY (Select XmlSchemaClauseTemplate='(#XmlSchemaDocType# #XmlSchemaName#)') as vXmlSchemaClauseTemplate
    CROSS APPLY (Select XmlSpecR1=REPLACE(XmlSchemaClauseTemplate, '#XmlSchemaName#', XmlSchemaName)) as vXmlSpecR1
    CROSS APPLY (Select XmlSpec=ISNULL(REPLACE(XmlSpecR1, '#XmlSchemaDocType#', XmlSchemaDocType),'')) as vXmlSpec
  ) as ComputeTypDefElements
  
  CROSS APPLY 
  (
  Select MatchType, SpecTags, startQuote, EndQuote
  From
    TypeBuildInfo
  Where Prms.isComputed=0 -- not a computed column
    And TypeBuildInfo.MatchType = Prms.UserType -- not a user defined type
  UNION ALL

  Select Prms.UserType, '', '', ''  -- user defined type is just specified by its name
  Where Prms.isComputed=0 -- not a computed column
    And Prms.UserType <> Prms.SystemType -- user defined type
  UNION ALL

  Select Prms.SystemType, '', '', ''  -- not one of the type above
  Where Prms.isComputed=0 -- not a computed column
    And Prms.SystemType NOT IN (select MatchType From TypeBuildInfo)

  UNION ALL
  Select '', '', '', '' -- computed column has no type
  Where Prms.isComputed=1 -- a computed column
  ) TypeSpecSel 

  CROSS APPLY (Select SpecTagsR1=Replace(SpecTags,   '#maxLen#',   SmaxLen))   as vtypeSpecTagsR1
  CROSS APPLY (Select SpecTagsR2=Replace(SpecTagsR1, '#NumPrec#',  SNumPrec))  as vtypeSpecTagsR2
  CROSS APPLY (Select SpecTagsR3=Replace(SpecTagsR2, '#NumScale#', SNumScale)) as vtypeSpecTagsR3
  CROSS APPLY (Select Spec=      REPLACE(specTagsR3, '#XmlSpec#',  XmlSpec))   as vSpec
  CROSS APPLY (Select TypeSpec=SchemaTypeName + MatchType + Spec)              as vTypeSpecSel

  -- ******************** f$.GetDataTypeExpressionElements Unit Tests ******************** 
  /*
  If type_id('f$.PostalCode') IS NOT NULL Drop Type f$.PostalCode;
  create type f$.PostalCode From Char(7);
  ;With 
    Params (UserType,         SystemType,    MaxLen, NumPrec, NumScale, IsComputed, IsXmlDocument,     XmlSchemaName) As
    (      
    
    Select  'f$.PostalCode',   'char',              7,       1,        1,          0,             1,               Null    union all
    Select  'Sysname',        'nvarchar',        128,       0,        0,          0,             0,               Null    union all
    Select  'nvarchar',       'nvarchar',         10,       0,        0,          0,             0,               Null    union all
    Select  'nvarchar',       'nvarchar',         -1,       0,        0,          0,             0,               Null    union all
    Select  'varchar',        'varchar',          10,       0,        0,          0,             0,               Null    union all
    Select  'varchar',        'varchar',          -1,       0,        0,          0,             0,               Null    union all
    Select  'nchar',          'nchar',            10,       0,        0,          0,             0,               Null    union all
    Select  'varbinary',      'varbinary',        -1,       0,        0,          0,             0,               Null    union all
    Select  'varbinary',      'varbinary',       256,       0,        0,          0,             0,               Null    union all
    Select  'char',           'char',             10,       0,        0,          0,             0,               Null    union all
    Select  'int',            'int',               4,       0,        0,          0,             0,               NULL    union all
    Select  'int',            'int',               4,       0,        0,          1,             0,               NULL    union all
    Select  'Bigint',         'Bigint',            8,       0,        0,          1,             0,               NULL    union all
    Select  'smallint',       'smallint',          2,       0,        0,          0,             0,               NULL    union all
    Select  'smallmoney',     'smallmoney',        2,       0,        0,          0,             0,               NULL    union all
    Select  'float',          'float',             8,      53,        0,          0,             0,               NULL    union all
    Select  'float',          'real',              4,      12,        0,          0,             0,               NULL    union all
    Select  'real',           'real',              4,      24,        0,          0,             0,               NULL    union all
    Select  'binary',         'binary',           10,       0,        0,          0,             0,               Null    union all
    Select  'numeric',        'numeric',           0,      10,        2,          0,             0,               Null    union all
    Select  'decimal',        'decimal',           0,      10,        2,          0,             0,               Null    union all
    Select  'time',           'time',              0,       0,        5,          0,             0,               Null    union all
    Select  'datetime',       'datetime',          0,       0,        5,          0,             0,               Null    union all
    Select  'datetime2',      'datetime2',         0,       0,        5,          0,             0,               Null    union all
    Select  'datetimeoffset', 'datetimeoffset',    0,       0,        5,          0,             0,               NULL    union all
    Select  'XML',            'XML',              -1,       0,        0,          0,             0,      'AnXmlSchName'    union all
    Select  'XML',            'XML',              -1,       0,        0,          0,             1,      'AnXmlSchName'    union all
    Select  'XML',            'XML',              -1,       0,        0,          1,             0,      'AnXmlSchName'    union all
    Select  'XML',            'XML',              -1,       0,        0,          0,             0,               NULL    union all
    Select  'XML',            'XML',              -1,       0,        0,          1,             0,               NULL    
    )
  Select D.*, Params.*
  From 
    Params 
    CROSS APPLY f$.GetDataTypeExpressionElements (Type_ID(UserType), TYPE_ID(SystemType), MaxLen, NumPrec, NumScale, IsComputed, IsXmlDocument, XmlSchemaName) AS D
  If type_id('f$.PostalCode') IS NOT NULL Drop Type f$.PostalCode;
   ******************** End of f$.GetDataTypeExpressionElements Unit Tests ******************** 
  */
)
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function that returns various aspects of columns definitions, for a given column or all columns a table if colname
-- parameter is NULL
-- This "overload" of results is nicely handled by the optimizer, which takes out the code associated to columns not 
-- asked in the final result
-- This function could be very useful to build a script that recreates a table.
-- ---------------------------------------------------------------------------------------------------------------------
exec f$.DropObj 'f$.ColInfo'
GO
--f$SignatureForCleanup
Create function f$.ColInfo(@tab sysname, @colName sysname) 
Returns Table
as
Return
(
With 
  Prm as 
  (
  Select *
  From 
--  (select PrmTab = 'f$.UnitTestColInfo', PrmCol = 'c3a') as vPrm
    (Select PrmTab=@tab, PrmCol=@ColName) as vPrm
    Cross Apply (select DbId=DB_ID()) vDbId
    Cross Apply (Select ObjId = OBJECT_ID(PrmTab)) as vObjId
  )
, tbSrc as 
  (
  Select Prm.*, T.Object_id, T.name
  From 
    Prm
    Cross Join Sys.Tables as T
  Where Prm.PrmTab IS NULL
  UNION ALL
  Select Prm.*, T.Object_id, T.name
  From 
    Prm 
    Join Sys.Tables as T
    On T.object_id = Prm.ObjId
  )
, tabInfo as
  ( 
  Select 
    tbSrc.Object_Id
  , tbSrc.DbId
  , vScn.Scn
  , vTn.Tn
  , vFullTbName.FullTbName
  , tbSrc.PrmCol
  From 
    tbSrc 
    Cross Apply (Select Scn=object_schema_name (object_id)) as vScn
    Cross Apply (Select Tn=Name) as vTn
    Cross Apply (Select FullTbName=QuoteName(Scn)+'.'+QuoteName(Tn)) as vFullTbName
  )
  --select * from tabInfo
, TbAndColumnInfos as 
  ( 
  Select T.Dbid, T.Scn, T.Tn, T.FullTbName, C.* 
  From 
    tabInfo T
    Join Sys.columns C
    On C.Object_id = T.Object_id
  Where T.PrmCol IS NULL
  UNION ALL
  Select T.Dbid, T.Scn, T.Tn, T.FullTbName, C.* 
  From 
    tabInfo T
    Join Sys.columns C
    On  C.Object_id = T.Object_id 
    And C.Name = T.PrmCol
  Where PrmCol IS NOT NULL
  )
  --Select * from TbAndColumnInfos
, colData as
  (
  Select 
    Tc.FullTbName
  , Tc.Scn
  , TC.Tn -- schema-less name
  , ComputedColNameInfo.*
  , TS.TypeSpec
  , TS.StartQuote
  , TS.EndQuote
  , Tc.collation_name
  , ComputedBasicColSpecElements.*
  , ComputedIdentitySpec.*
  , ComputedDefConstraint.*
  , ComputedChkConstraint.*
  , FullColDef.*
  , Tc.object_id 
  , Tc.column_id as ColOrd
  , Tc.system_type_id
  , Tc.user_type_id
  , TS.systemType
  , TS.userType
  , TS.charMaxLen
  , Tc.max_length 
  , Tc.precision as numPrecision
  , Tc.scale as numScale
  , Tc.is_nullable as is_nullable
  , Tc.is_computed as is_computed
  , Scc.definition as SrcComputedColDef
  , II.column_id as IdenColumn_id
  , II.Increment_value as Incr
  , Tc.is_sparse 
  From
    TbAndColumnInfos TC

    left loop join
    sys.types ST -- ne plus utiliser type_name() en dehors du contexte de Bd
    On ST.user_type_id = Tc.user_type_id      

    left loop join
    sys.computed_columns scc -- pour obtenir définition de la colonne calculée
    on Tc.is_computed = 1 And -- optimiser avant joindre
       scc.object_id = Tc.object_id And
       scc.column_id = Tc.column_id

    left loop Join -- un seule par table
    sys.identity_columns II
    On II.object_id = Tc.object_id And 
       II.column_id = Tc.column_id

    left loop Join -- pas nécessairement de défaut
    sys.default_constraints def
    On  def.parent_object_id = Tc.object_id And
        def.parent_column_id = Tc.column_id
        
    left loop Join -- pas nécessairement de défaut
    sys.check_constraints Chk
    On  chk.parent_object_id = Tc.object_id And
        chk.parent_column_id = Tc.column_id
        
    LEFT loop Join -- get a match for the schema collection
    sys.column_xml_schema_collection_usages XSCU
    On XSCU.object_id = Tc.object_id And
       XSCU.column_id = Tc.column_id 
    
    LEFT loop Join -- get a match for 
    sys.xml_schema_collections XSC
    On XSC.xml_collection_id = XSCU.xml_collection_id 
 
    cross APPLY 
    f$.GetDataTypeExpressionElements 
    ( Tc.user_type_id
    , Tc.system_type_id
    , Tc.max_length
    , Tc.Precision
    , Tc.scale
    , Tc.is_computed 
    , Tc.is_xml_document 
    , XSC.name 
    ) as TS

    Cross Apply
    (
    Select *
    From 
                  (Select UnQuotedDbCollatedCn=TC.Name collate database_default) as vUnQuotedDbCollatedCn
      CROSS APPLY (Select Cn=Replace('[#Cn#] ', '#Cn#', UnQuotedDbCollatedCn)) as vColName
    ) as ComputedColNameInfo

    Cross Apply
    (
    Select *
    From 
                  (Select TypeDef = IIF(Tc.is_computed = 0, ' '+TS.TypeSpec, '')) as vTypeDef
      CROSS APPLY (Select ComputedColDef=ISNULL(Scc.Definition, '')) as vComputedColDef
      CROSS APPLY (Select NullSpec=IIF(TC.is_computed = 1, '', IIF(TC.is_nullable=1, ' NULL', ' Not NULL'))) as vsNullSpec
      CROSS APPLY (Select CollationClause=ISNULL(' COLLATE '+TC.collation_name,'')) as vCollationClause
    ) as ComputedBasicColSpecElements

    Cross Apply
    (
    Select *
    From
                  (Select IsIdentityCol = Case When II.column_id IS NOT NULL Then 1 Else 0 End) as vIsIdentityCol
      CROSS Apply (Select StrSeed=convert(nvarchar, II.Seed_Value)) as vStrSeed
      CROSS Apply (Select StrIncr=convert(nvarchar, II.Increment_value)) as vStrIncr
      CROSS Apply (Select IdentitySpecTemplate=' Identity(#StrSeed#, #StrIncr#)') as vIdentityExpressionTemplate
      CROSS APPLY (Select IdentitySpecR1=Replace (IdentitySpecTemplate, '#StrSeed#', StrSeed)) as vIdentityR1
      CROSS APPLY (Select IdentitySpec=ISNULL(Replace (IdentitySpecR1, '#StrIncr#', StrIncr), '')) as vIdentitySpec
    ) as ComputedIdentitySpec

    Cross Apply 
    (
    Select *
    From 
                  (Select DefConstraintDefinition=def.definition) as vDefConstraintDefinition
      CROSS APPLY (Select DefConstraintTemplate=' Default #DefConstraintDefinition#') as DefConstraintTemplate
      CROSS APPLY (Select DefConstraint=ISNULL(Replace(DefConstraintTemplate, '#DefConstraintDefinition#', DefConstraintDefinition), '')) as vDefConstraint
      CROSS Apply (Select NamedDefConstraintTemplate=' Constraint #DefConstraintName##DefConstraint#') as vNamedDefConstraintTemplate
      CROSS Apply (Select DefConstraintName=def.name) as vDefConstraintName
      CROSS APPLY (Select NamedDefContraintR1=REPLACE(NamedDefConstraintTemplate, '#DefConstraintName#', DefConstraintName)) as vNamedDefContraintR1
      CROSS APPLY (Select NamedDefContraint=ISNULL(REPLACE(NamedDefContraintR1, '#DefConstraint#', DefConstraint),'')) as vNamedDefConstraint
    ) as ComputedDefConstraint

    Cross Apply
    (
    Select *
    From 
                  (Select ChkConstraintDefinition=Chk.definition) as vChkConstraintDefinition
      CROSS APPLY (Select ChkConstraintTemplate=' Check #ChkConstraintDefinition#') as ChkConstraintTemplate
      CROSS APPLY (Select ChkConstraint=ISNULL(Replace(ChkConstraintTemplate, '#ChkConstraintDefinition#', ChkConstraintDefinition), '')) as vChkConstraint
      CROSS Apply (Select NamedChkConstraintTemplate=' Constraint #ChkConstraintName##ChkConstraint#') as vNamedChkConstraintTemplate
      CROSS APPLY (Select NamedChkContraintR1=REPLACE(NamedChkConstraintTemplate, '#ChkConstraint#', ChkConstraint)) as vNamedChkConstraintR1
      CROSS Apply (Select ChkConstraintName=chk.name) as vChkConstraintName
      CROSS APPLY (Select NamedChkContraint=ISNULL(REPLACE(NamedChkContraintR1, '#ChkConstraintName#', ChkConstraintName), '')) as vNamedChkContraint
    )  as ComputedChkConstraint

    Cross Apply
    (
    Select *
    From 
                  (Select ColDef=Cn + ComputedColDef + TypeDef + IdentitySpec + NullSpec + DefConstraint + ChkConstraint) as vColDef
      CROSS Apply (Select ColDefAndCN=Cn + ComputedColDef + TypeDef + IdentitySpec + NullSpec + NamedDefContraint + NamedChkContraint) as vColDefAndCN
      CROSS Apply (Select ColDefCollated=Cn + ComputedColDef + TypeDef + CollationClause + IdentitySpec + NullSpec + DefConstraint + ChkConstraint) as vColDefCollated
      CROSS Apply (Select ColDefCollatedAndCN=Cn + ComputedColDef + TypeDef + CollationClause + IdentitySpec + NullSpec + NamedDefContraint + NamedChkContraint) as vColDefCollatedAndCN
    ) as FullColDef
  )  
Select 
  c.*
From 
  colData C

-- ------------------------------------------------------------------------
/*
CREATE XML SCHEMA COLLECTION f$.TSTColInfo AS  
N'<?xml version="1.0" encoding="UTF-16"?>  
<xsd:schema targetNamespace="http://schemas.microsoft.com/sqlserver/2004/07/adventure-works/ProductModelManuInstructions"   
   xmlns          ="http://schemas.microsoft.com/sqlserver/2004/07/adventure-works/ProductModelManuInstructions"   
   xmlns:xsd="http://www.w3.org/2001/XMLSchema" >  
    <xsd:element  name="root">  
    </xsd:element>  
</xsd:schema>'
go
if object_id('f$.UnitTestColInfo') is not null drop table f$.UnitTestColInfo
Create table f$.UnitTestColInfo
(
  i int identity (1,1)  not null
, c nvarchar(max) not null
, X XML (DOCUMENT f$.TSTColInfo)
, X2 XML (CONTENT f$.TSTColInfo)
, c2 nvarchar(10) null default ''
, c3 varchar(10) null default ''
, c3a varchar(10) not null Constraint defBlk default '' Constraint chkLenc3a Check (len(c3a)=10)
, sv sql_variant
, getInfo as getdate()
, d decimal (10,3)
, n numeric (10,3)
, d2 decimal (10)
, n2 numeric (10)
, SdaT SMALLdatetime
, daT datetime
, da datetime2(5)
, ti time(5)
, c4 timestamp not null
, r real
, f float 
, T tinyint
)
          Select 1, * from f$.ColInfo('f$.UnitTestColInfo',  NULL)
union all Select 6, * from f$.ColInfo('f$.UnitTestColInfo', 'c3') 
Order by 1, FullTbName, colOrd
drop table f$.UnitTestColInfo
go
drop XML SCHEMA COLLECTION f$.TSTColInfo
*/
-- ------------------------------------------------------------------------
)
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function to get info on index
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.IndexInfo'
GO
--f$SignatureForCleanup
Create function f$.IndexInfo (@tab sysname, @Index_id Int)
returns table
as
return
(
With 
  prm as 
  (
  Select @Tab as prmTab, @Index_id as prmIndex_id
  -- spécifier nom de table pour index d'une table spécifique ou null pour toutes
  -- spécifier index_id pour index spécifique d'une table ou null pour toutes les index d'une table
  --Select convert(sysname, NULL) as prmTab, convert(int, NULL) as prmIndex_Id) 
  )
, InfosTbEtIndex as 
  (
    Select -- no NULL PARAM
    Prm.*
  , object_schema_name(I.object_id) as Scn
  , I.object_id as ObjId
  , f$.FullObjName (I.object_id) as FullTbName
  , Object_name (I.object_id) as Tb
  , I.*
  From 
    Prm 
    Cross join 
    Sys.indexes I
  Where OBJECTPROPERTYEX (I.object_id, 'IsMsShipped')=0
  )
  --Select * From InfosTbEtIndex
, SchemasAndIndexInfos as    -- Trick to get better optimization when some parameters are NULL
  (
  Select *-- no NULL PARAM
  From 
    InfosTbEtIndex
  Where prmTab IS NOT NULL And Index_id IS NOT NULL 
    And object_id = object_id(prmTab)
    And Index_id = Index_id
  UNION ALL -- NULL PARAM on Index_id only
  Select *
  From InfosTbEtIndex
  Where prmTab IS NOT NULL And Index_id IS NULL 
    And object_id = object_id(prmTab)
  UNION ALL -- NULL PARAM on both params
  Select *
  From InfosTbEtIndex
  Where prmTab IS NULL And prmIndex_id IS NULL 
  )
  --select * from SchemasAndIndexInfos
, IndexParts as
  (
  Select 
    f$.FullObjName(I.Object_id) collate database_default as FullTbName
  , I.Tb    
  , I.scn
  , I.ObjId
  , I.object_id 
  , I.name 
  , I.name as IdxName
  , I.index_id
  , I.type_desc Collate Database_default as Type_desc
  , I.is_unique
  , case When I.is_unique = 1 Then 'unique ' else '' End as UniqueClause
  , I.is_unique_constraint 
  , I.is_primary_key 
  , I.data_space_id
  , s.no_recompute 
  , I.fill_factor
  , I.has_filter
  , I.ignore_dup_key
  , I.is_disabled
  , I.is_padded
  , I.allow_page_locks
  , I.allow_row_locks
  , I.filter_definition -- SQL2008 and above feature
  , F.name as FileGroupName
  , ROW_NUMBER () 
    over (Partition By I.Object_id
          order by 
            Case 
              When I.type_desc in ('clustered') 
              then 1 
              Else 0 
            End desc
          , I.name desc) as CreateIndexSeq
  , ROW_NUMBER () 
    over (Partition By I.Object_id
          order by 
            Case 
              When I.type_desc in ('clustered') 
              then 0 
              Else 1 
            End desc
          , I.name desc) as DropIndexSeq
  from 
    SchemasAndIndexInfos As I
    join 
    sys.filegroups F
    ON F.data_space_id = I.data_space_id
    left JOIN 
    sys.stats S
    On I.object_id = s.object_id AND I.index_id = s.stats_id
  Where 
      I.type_desc IN ('clustered', 'nonclustered')    
  )
  --Select * From IndexParts
, CompositeIndexPartsStep1 as
  (
  Select 
      P.DropIndexSeq
    , P.CreateIndexSeq
    , P.FullTbName
    , P.Tb    
    , P.scn
    , P.ObjId
    , P.object_id 
    , P.idxName
    , P.index_id
    , P.type_desc 
    , P.is_unique
    , P.UniqueClause
    , P.is_unique_constraint 
    , P.is_primary_key 
    , (
      Select count(*) 
      From sys.index_columns as ic
      Where ic.object_id = P.object_id
        And ic.index_id = P.index_id 
        And ic.is_included_column = 0
      ) as NbOfIndexedCols
    , (
      Select top 1 COL_NAME(ic.object_id, ic.column_id) 
      From sys.index_columns as ic
      Where ic.object_id = P.object_id
        And ic.index_id = P.index_id 
        And ic.is_included_column = 0
      Order by ic.object_id, ic.index_id, ic.key_ordinal 
      ) as FirstCol
    , LTRIM
      (
        f$.AdjConcatRS
        ( 
          ', '
        , (
          Select f$.CMax(', '+Quotename(COL_NAME(ic.object_id, ic.column_id))+ Case When IC.is_descending_key = 1 Then ' #Desc#' Else ' #Asc#' End) as [text()]
          From sys.index_columns as ic
          Where ic.object_id = P.object_id
            And ic.index_id = P.index_id 
            And ic.is_included_column = 0
          Order by ic.object_id, ic.index_id, ic.key_ordinal 
          For XML Path('')
          ) 
        )
      )  as BuildColsIndex
    , f$.AdjConcatRS
      ( 
        ', '
      , (
        Select f$.CMax(', '+Quotename(COL_NAME(ic.object_id, ic.column_id))) as [text()]
        From sys.index_columns as ic
        Where ic.object_id = P.object_id
          And ic.index_id = P.index_id 
          And ic.is_included_column = 1
        Order by ic.object_id, ic.index_id, ic.key_ordinal 
        For XML Path('')
        ) 
      ) as IncludedCols
    , P.data_space_id
    , P.no_recompute
    , P.fill_factor
    , P.ignore_dup_key
    , P.is_disabled
    , P.is_padded
    , P.allow_page_locks
    , P.allow_row_locks
    , P.has_filter
    , P.filter_definition -- SQL2008 and above feature
    , FileGroupName
    From 
      IndexParts P
  )
  --Select * From CompositeIndexParts
, CompositeIndexParts as
  (
  Select 
    CS1.*
  , B2.s as ColsIndexDef
  , L2.s as ColsIndexList
  From 
    CompositeIndexPartsStep1 CS1
    CROSS APPLY f$.IReplace (CS1.BuildColsIndex, '#Desc#', 'DESC') as B1
    CROSS APPLY f$.IReplace (B1.s, '#Asc#', '') as B2
    CROSS APPLY f$.IReplace (CS1.BuildColsIndex, '#Desc#', '') as L1
    CROSS APPLY f$.IReplace (L1.s, '#Asc#', '') as L2
  )
, PrimaryKeyUniqueConstraintFlags as
  (
  Select *
  From
    (
    Values (1, 1), (1,0), (0, 0), (0, 1) 
    ) as T(is_primary_key, is_unique_constraint)
  )
  -- Select * From PrimaryKeyUniqueConstraintFlags
, TemplatesMappingForBuildingDropAndCreateForGivenIndexAttributes as 
  (
  Select
    is_Primary_Key
  , Is_unique_constraint
  , Case 
      When is_primary_key = 1 Or is_unique_constraint = 1
      Then 'If Exists(select * from sys.key_constraints Where name = "#idxName#") Alter Table #Tab# Drop Constraint [#idxName#]; '
      Else 'If Exists(Select * From Sys.Indexes Where Object_id = object_ID("#Tab#") and Name="#IdxName#") Drop Index [#IdxName#] On #tab#; '
    End As DropIndexClause
  , Case 
      When is_primary_key = 1
      Then 'Alter Table #Tab# ADD Constraint [#idxName#] PRIMARY KEY #Type_desc# (#ColsIndexDef#) #WithIndexClauseTemplate# ON [#FileGroupName#]; '
      When is_unique_constraint = 1
      Then 'Alter Table #Tab# ADD Constraint [#idxName#] UNIQUE #Type_desc# (#ColsIndexDef#) #WithIndexClauseTemplate# ON [#FileGroupName#]; '
      Else 'create #UniqueClause# #type_desc# Index [#IdxName#] On #tab# (#ColsIndexDef#) #IncludeClauseTemplate#  #IndexFilterClauseTemplate# #WithIndexClauseTemplate# ON [#FileGroupName#]; '
    End As AddIndexClause
  , 'include (#IncludedCols#)' as IncludeClauseTemplate
  , ' With (PAD_INDEX = #PAD#, STATISTICS_NORECOMPUTE = #STATS#, IGNORE_DUP_KEY = #DUP#, ALLOW_ROW_LOCKS = #ROWLOCK#, ALLOW_PAGE_LOCKS = #PAGLOCK#  #FillFactorTemplateForWithTemplate#) ' as WithIndexClauseTemplate
  , ', FILLFACTOR = #idxFillFactor#' as FillFactorTemplateForWithTemplate
  , ' WHERE #FilterExpression# ' as IndexFilterClauseTemplate
  From 
    PrimaryKeyUniqueConstraintFlags
  )
--Select * From TemplatesMappingForBuildingDropAndCreateForGivenIndexAttributes
Select 
  DropIndexClause.s As DropIndex, C10.s As CreateIndex, C11.s As CreateIndexWithoutWithClause, P.DropIndexSeq, P.CreateIndexSeq
, P.FullTbName, P.Tb, P.Scn, P.ObjId
, P.object_id, P.idxName, P.index_id, P.type_desc, P.is_unique, P.UniqueClause
, P.is_unique_constraint, P.is_primary_key, P.NbOfIndexedCols, P.FirstCol--, PBuildColsIndex
, P.IncludedCols 
, P.data_space_id, P.no_recompute, P.fill_factor, P.ignore_dup_key, P.is_disabled, P.is_padded
, P.allow_page_locks, P.allow_row_locks, P.has_filter, P.filter_definition, P.FileGroupName, P.ColsIndexDef, P.ColsIndexList
From 
  Prm
  Cross Join
  CompositeIndexParts P
  JOIN 
  TemplatesMappingForBuildingDropAndCreateForGivenIndexAttributes T
  ON    T.Is_Primary_key = P.is_primary_key And T.is_unique_constraint = P.is_unique_constraint

  CROSS APPLY f$.iReplace (T.DropIndexClause, '#tab#', P.FullTbName) as D0
  CROSS APPLY f$.iQReplace (D0.s, '#idxName#', p.IdxName) as DropIndexClause

  CROSS APPLY f$.iReplace (T.AddIndexClause, '#UniqueClause#', P.UniqueCLause) as C0
  CROSS APPLY f$.iReplace (c0.S, '#type_desc#', P.type_desc) as c1
  CROSS APPLY f$.iReplace (c1.S, '#IdxName#', P.IdxName) as c2
  CROSS APPLY f$.iReplace (c2.s, '#tab#', P.FullTbName) as c3
  CROSS APPLY f$.iReplace (c3.s, '#colsIndexDef#', P.colsIndexDef) as c3a
  CROSS APPLY f$.iReplace (c3a.s, '#FileGroupName#', P.FileGroupName) as BaseAddIndexClauseDone

  CROSS APPLY f$.iReplace (BaseAddIndexClauseDone.s, '#IncludeClauseTemplate#', Case When P.IncludedCols <> '' Then T.IncludeClauseTemplate Else '' End) as c4b
  CROSS APPLY f$.iReplace (c4b.s, '#IncludedCols#', P.IncludedCols) as BaseAddIndexAndIncCols

  CROSS APPLY f$.iReplace (T.WithIndexClauseTemplate, '#STATS#', f$.OnOff(P.no_recompute)) as c6a
  CROSS APPLY f$.iReplace (c6a.s, '#PAD#', f$.OnOff(P.is_Padded)) as c6b
  CROSS APPLY f$.iReplace (c6b.s, '#DUP#', f$.OnOff(P.ignore_dup_key)) as c6c
  CROSS APPLY f$.iReplace (c6c.s, '#ROWLOCK#', f$.OnOff(P.allow_row_locks)) as c6d
  CROSS APPLY f$.iReplace (c6d.s, '#PAGLOCK#', f$.OnOff(P.allow_page_locks)) as c6e
  CROSS APPLY f$.iReplace (c6e.s, '#FillFactorTemplateForWithTemplate#', Case When P.fill_factor > 0 Then T.FillFactorTemplateForWithTemplate Else '' End) as c6f
  CROSS APPLY f$.iReplace (c6f.s, '#idxFillFactor#', convert(nvarchar, P.fill_factor)) as WithIndexClauseDone

  CROSS APPLY f$.iReplace (BaseAddIndexAndIncCols.s,  '#IndexFilterClauseTemplate#', Case When P.has_filter = 0 Then '' Else T.IndexFilterClauseTemplate End) as c8a
  CROSS APPLY f$.iReplace (c8a.s,  '#FilterExpression#', ISNULL(P.filter_definition, '')) as BaseAddIndexAndIncColsAndFilterDone
  CROSS APPLY f$.iReplace (BaseAddIndexAndIncColsAndFilterDone.s, ' #WithIndexClauseTemplate#', WithIndexClauseDone.s) as c10
  CROSS APPLY f$.iReplace (BaseAddIndexAndIncColsAndFilterDone.s, ' #WithIndexClauseTemplate#', '') as c11
Where 
      Prm.prmTab is NULL Or P.object_id = object_id(prm.prmTab) 
  And P.Index_id = ISNULL(prm.PrmIndex_id, P.Index_id)
  And P.type_desc in ('CLUSTERED', 'NONCLUSTERED')   
)  
-- Select * from f$.indexInfo (null, null) order by tb
/*
exec f$.dropobj 'dbo.dummyTest'
create table dbo.dummyTest (i int, j int) create index ii on dbo.dummyTest (i desc, j)
Select * from f$.indexInfo ('dbo.dummyTest', null)
exec f$.dropobj 'dbo.dummyTest'
*/
-- Select * from f$.indexInfo ('dbo.existepas', null)
-- Select * from f$.indexInfo ('dbo.gpm_e_ele', null)
-- Select * from f$.indexInfo ('dbo.gpm_e_ele', null) where IncludedCols = '' -- à blanc quand il n'y en a pas
-- Select * from f$.indexInfo ('dbo.gpm_e_ele', 1)
GO
-- ------------------------------------------------------------------------
-- Return index info by index name
-- ------------------------------------------------------------------------
Exec f$.DropObj 'f$.IndexInfoByIndexName'
GO
--f$SignatureForCleanup
Create function f$.IndexInfoByIndexName (@tab sysname, @idxName sysname)
returns table
as
return
(
  Select Inf.* 
  From f$.IndexInfo (@tab, (INDEXPROPERTY (Object_id(@tab), @idxName , 'indexId'))) Inf
)  -- f$.GenIndexScript
-- Select * From f$.IndexInfoByIndexName (NULL, NULL) Order By FullTbName, SeqCreationIndex, is_Primary_key, is_unique_constraint
-- Select * From f$.IndexInfoByIndexName ('dbo.gpm_e_ele', NULL) Order By FullTbName, SeqCreationIndex, is_Primary_key, is_unique_constraint
-- Select * From f$.IndexInfoByIndexName ('dbo.gpm_e_ele', 'gpm_e_ele_org') Order By FullTbName, SeqSuppressionIndex, is_Primary_key, is_unique_constraint
GO
Exec f$.DropObj 'f$.FullTextInfo'
GO
--f$SignatureForCleanup
Create Function f$.FullTextInfo (@tb sysname)
Returns Table
as
Return
(
With 
  Prm (PrmObjid) as
  (
  Select Object_id(@tb) as ObjId Where Object_id(@tb) IS NOT NULL
  UNION ALL
  Select OBJECT_ID From Sys.fulltext_indexes Where Object_id(@tb) IS NULL
  )
, ColsFullTextIdx as
  (
  select 
    fidxc.object_id
  , f$.FullObjName (object_id) as Tb
  , COL_NAME(object_id, column_id) as Cn
  , ISNULL(' TYPE COLUMN '+COL_NAME(object_id, type_column_id), '') as TypCn
  , ISNULL(' LANGUAGE '+name, '') as Lang 
  , case when STATISTICAL_SEMANTICS = 0 Then '' Else 'STATISTICAL_SEMANTICS' End as STATISTICAL_SEMANTICS
  from 
    Prm
    JOIN 
    sys.fulltext_index_columns fidxc
    ON fIdxc.object_id = PrmObjid
    Left join 
    sys.fulltext_languages flang
    ON flang.lcid = fidxc.language_id                  
  )
, ColsFullTextIdxAndSyntax as
  (
/*===SyntaxColsFullTextIndex===
#Cn##TypCn##Lang##STATISTICAL_SEMANTICS#
===SyntaxColsFullTextIndex===*/
  Select C.*, R1.finalReplace as ColSyntax
  From 
    f$.GetCommentFromSqlObj(Object_id('f$.FullTextInfo'), '===SyntaxColsFullTextIndex===') as B
    CROSS JOIN ColsFullTextIdx as C
    Cross Apply f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(B.CommentContent, (Select C.* For XML Raw, Type)) as R1
  )
, FullTxtIdx as
  (
/*===SyntaxCreateFullTextIndex===
CREATE FULLTEXT INDEX ON #tb#
(#colsFulText#)
KEY INDEX #KeyIndex#
ON #CatalogName#
WITH CHANGE_TRACKING = #change_tracking_state_desc##StopList#
===SyntaxCreateFullTextIndex===*/

/*===SyntaxDropFullTextIndex===
DROP FULLTEXT INDEX ON #tb#
===SyntaxDropFullTextIndex===*/
  select 
    f$.FullObjName (fIdx.object_id) as Tb
  , idx.name as KeyIndex
  , fc.name as CatalogName
  , fIdx.change_tracking_state_desc
  , ISNULL(', STOPLIST = '+SL.name, '') as StopList
  , f$.ConcatInfoFromXML(1, ', ', (Select ColSyntax From ColsFullTextIdxAndSyntax S Where S.Object_id = fidx.object_id For XML RAW, Type)) as colsFulText
  from 
     PRM
     JOIN 
     sys.fulltext_indexes as fidx
     ON fIdx.object_id = Prm.PrmObjid
     Join 
     sys.indexes as idx
     ON Idx.object_id = fIdx.object_id And Idx.index_id = fIdx.unique_index_id
     join 
     sys.fulltext_catalogs as fc
     on fc.fulltext_catalog_id = fIdx.fulltext_catalog_id
     Left Join 
     Sys.fulltext_stoplists SL
     ON SL.stoplist_id = fIdx.stoplist_id
   )
 Select F.*, RFC.finalReplace as AddFullTextIndex, RFD.finalReplace as DropFullTextIndex
 From 
   f$.GetCommentFromSqlObj(Object_id('f$.FullTextInfo'),'===SyntaxCreateFullTextIndex===') as BC
   CROSS JOIN f$.GetCommentFromSqlObj(Object_id('f$.FullTextInfo'),'===SyntaxDropFullTextIndex===') as BD
   CROSS JOIN FullTxtIdx as F
   Cross Apply f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(BC.CommentContent, (Select F.* For XML Raw, Type)) as RFC
   Cross Apply f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(BD.CommentContent, (Select F.* For XML Raw, Type)) as RFD
)
GO
-- ------------------------------------------------------------------------
-- Get foreign key info given an foreign key id
-- ------------------------------------------------------------------------
Exec f$.DropObj 'f$.ForeignKeyInfo'
GO
--f$SignatureForCleanup
create function f$.ForeignKeyInfo (@FkId Int)
returns table 
AS
RETURN
(
With 
  ForeignKeySelector as 
  (
  Select * From Sys.foreign_keys Where @FkId is NULL
  UNION ALL
  Select * From Sys.foreign_keys Where @FkId is NOT NULL And object_id = @Fkid
  )
, ForeignKeyData as
  (
  select 
    object_schema_name(f.parent_object_id) as Scn
  , object_name(f.parent_object_id) Tab
  , f$.FullObjName (f.parent_object_id) as FullTbName
  , f.parent_object_id
  , f.object_id
  , F.name as FkName
  , f$.AdjConcatRS
    (
      ', '      
    , (
      Select convert(nvarchar(max), ', '+Quotename(COL_NAME (Fkc.parent_object_id, Fkc.parent_column_id ))) as [text()]
      From sys.foreign_key_columns Fkc
      Where constraint_object_id = F.object_id
      Order BY FKc.constraint_column_id 
      FOR XML PATH('') 
      ) 
    ) as FkCols
  , f$.FullObjName (F.referenced_object_id) as RefTbName
  , Idx.ColsIndexList as RefKeyCols
  , Replace (F.delete_referential_action_desc, '_', ' ') as delete_referential_action_desc
  , Replace (F.update_referential_action_desc, '_', ' ') as update_referential_action_desc
  from 
    ForeignKeySelector f
    cross apply
    f$.IndexInfo (f$.FullObjName(f.referenced_object_id), f.key_index_id) as Idx
  Where F.object_id = ISNULL(@FkId, F.object_id)
  )
, ForeignKeyTemplates as
  (
  Select 
    '
     Alter Table #tab# Add Constraint [#FKName#] FOREIGN KEY (#FkCols#) 
     References #RefTbName# (#RefkeyCols#)
     ON DELETE #delete_referential_action_desc# ON UPDATE #update_referential_action_desc#; ' collate Database_Default as AddForeignKey
  , 'If Exists(Select * From sys.foreign_keys where name = "#FKName#") alter table #tab# drop constraint [#FKName#]; ' collate database_default as DropForeignKey
  )
select A7.s as AddForeignKey, d2.s as DropForeignKey, Fkd.*
from 
  ForeignKeyData Fkd
  cross join ForeignKeyTemplates Fkt 
  cross apply f$.iReplace(Fkt.DropForeignKey, '#Tab#', Fkd.FullTbName)  as d1
  cross apply f$.iQReplace(d1.s, '#FkName#', Fkd.FkName)  as d2
  cross apply f$.iReplace(Fkt.AddForeignKey, '#Tab#', Fkd.FullTbName)  as A1
  cross apply f$.iReplace(A1.s, '#FkName#', Fkd.FkName)  as A2
  cross apply f$.iReplace(A2.s, '#FkCols#', Fkd.FkCols)  as A3
  cross apply f$.iReplace(A3.s, '#RefTbName#', Fkd.RefTbName)  as A4
  cross apply f$.iReplace(A4.s, '#RefkeyCols#', Fkd.RefkeyCols)  as A5
  cross apply f$.iReplace(A5.s, '#delete_referential_action_desc#', Fkd.delete_referential_action_desc)  as A6
  cross apply f$.iQReplace(A6.s, '#update_referential_action_desc#', Fkd.update_referential_action_desc)  as A7
)
-- Select * From f$.ForeignKeyInfo (NULL)
-- Select * From f$.ForeignKeyInfo (Object_id('FK_GRICS_GPM_E_PI_PARTICIPANT_RENCONTRE_GPM_E_PI_RENCONTRE_40221')) as Fk
GO
-- ------------------------------------------------------------------------
-- Get foreign key info by its name
-- ------------------------------------------------------------------------
Exec f$.DropObj 'f$.ForeignKeyInfoByName'
GO
--f$SignatureForCleanup
create function f$.ForeignKeyInfoByName (@FkName sysname)
returns table 
AS
RETURN
(
Select * From f$.ForeignKeyInfo (Object_Id(@FkName))
-- Select * From f$.ForeignKeyInfoByName (NULL)
-- Select * From f$.ForeignKeyInfoByName ('FK_GRICS_GPM_E_PI_PARTICIPANT_RENCONTRE_GPM_E_PI_RENCONTRE_40221') as Fk
)
GO
-- ------------------------------------------------------------------------
-- Get foreign key add and drop for a table
-- ------------------------------------------------------------------------
Exec f$.DropObj 'f$.ForeignKeyInfoByTable'
GO
--f$SignatureForCleanup
create function f$.ForeignKeyInfoByTable (@Tab sysname)
returns table 
AS
RETURN
(
With
  ForeignKeySelector as
  (
  Select * 
  From 
    Sys.foreign_keys FK
  Where @Tab IS NULL
  UNION ALL
  Select FK.* 
  From 
    Sys.foreign_keys FK
  Where @Tab IS NOT NULL
    And FK.parent_object_id = OBJECT_ID(@Tab)
  )
Select Fki.* 
From 
  ForeignKeySelector Fks
  Cross Apply f$.ForeignKeyInfo (Fks.object_id) Fki
-- Select * From f$.ForeignKeyInfoByTable (NULL)
-- Select * From f$.ForeignKeyInfoByTable ('GPM_E_PI_PARTICIPANT_RENCONTRE') as Fk
)
GO
-- ------------------------------------------------------------------------
-- Get foreign key add and drop for a table
-- ------------------------------------------------------------------------
Exec f$.DropObj 'f$.ForeignKeyInfoByRefTable'
GO
--f$SignatureForCleanup
create function f$.ForeignKeyInfoByRefTable (@RefTab sysname)
returns table 
AS
RETURN
(
With
  ForeignKeySelector as
  (
  Select * 
  From 
    Sys.foreign_keys FK
  Where @RefTab IS NULL
  UNION ALL
  Select FK.* 
  From 
    Sys.foreign_keys FK
  Where @RefTab IS NOT NULL
    And FK.referenced_object_id = OBJECT_ID(@RefTab)
  )
Select Fki.* 
From 
  ForeignKeySelector Fks
  Cross Apply f$.ForeignKeyInfo (Fks.object_id) Fki
-- Select * From f$.ForeignKeyInfoByTable (NULL)
-- Select * From f$.ForeignKeyInfoByTable ('GPM_E_PI_PARTICIPANT_RENCONTRE') as Fk
)
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function that returns full information about a table.
-- One is a plain column list, the other is column list definition as in a create table
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.TableInfo'
GO
--f$SignatureForCleanup
Create Function f$.TableInfo (@Tab sysname)
Returns Table 
as
Return 
(
With 
  TabSelector as 
  (
  Select T.* From Sys.Tables T Where @Tab is NULL
  UNION ALL
  Select T.* From Sys.Tables T Where @Tab is NOT NULL And T.Object_id = Object_Id(@Tab) 
  )
, TabLevelInfo as
  (
  Select 
    f$.FullObjName(T.object_id) as FullTbName
  , f$.UnQuoteName(f$.FullObjName(T.object_id)) as UnQuotedFullTbName
  , OBJECT_SCHEMA_NAME(T.object_id) as Scn
  , name as Tn
  , Objectpropertyex(T.Object_id, 'TableHasIdentity') as TabHasIdentity
  , T.* 
  From 
    tabSelector T
  )
, TabLevelInfoAndTabLevelAction as
  (
  Select 
    T.*
  , Case When T.TabHasIdentity = 1 Then r0.s + ' ON' Else '' End as IdentityOn
  , Case When T.TabHasIdentity = 1 Then r0.s + ' OFF' Else '' End as IdentityOff
  From 
    tabLevelInfo T
    CROSS APPLY f$.iReplace('Set Identity_insert #FullTbName# ', '#FullTbName#', T.FullTbName) as r0
  )
, MostTableComponents as
  (
  Select 
    FullTbName, UnQuotedFullTbName, object_id, Scn, Tn, IdentityOn, IdentityOff
  , f$.ConcatInfoFromXML(1, ',', (Select Cn, ColOrd From f$.ColInfo (Ts.FullTbName, NULL) For XML raw, type)) as AllCols 
  , f$.ConcatInfoFromXML(1, ',', (Select cn as Cn, ColOrd From f$.ColInfo (Ts.FullTbName, NULL) Where System_type_id <> 189 And is_computed = 0 For XML raw, type)) as ValidInsertCols 
  , f$.ConcatInfoFromXML(1, nchar(10)+',', (Select ColDef, ColOrd From f$.ColInfo (Ts.FullTbName, NULL) For XML Raw, type)) as ColsDef
  , f$.ConcatInfoFromXML(1, nchar(10)+',', (Select ColDefCollated, ColOrd From f$.ColInfo (Ts.FullTbName, NULL) For XML Raw, type)) as ColsDefCollated
  , f$.ConcatInfoFromXML(1, nchar(10)+',', (Select ColDefAndCN, ColOrd From f$.ColInfo (Ts.FullTbName, NULL) For XML Raw, type)) as ColsDefAndCN
  , f$.ConcatInfoFromXML(1, nchar(10)+',', (Select ColDefCollatedAndCN, ColOrd From f$.ColInfo (Ts.FullTbName, NULL) For XML Raw, type)) as ColsDefCollateAndCN
  , f$.ConcatInfoFromXML(0, '',  (Select CreateIndex, createIndexSeq From f$.IndexInfo(Ts.FullTbName, NULL) For XML Raw, type)) as CreateIndexes
  , f$.ConcatInfoFromXML(0, '',  (Select CreateIndexWithoutWithClause, createIndexSeq From f$.IndexInfo(Ts.FullTbName, NULL) For XML Raw, type)) as CreateIndexesWithoutWithClause
  , f$.ConcatInfoFromXML(0, '',  (Select DropIndex, DropIndexSeq From f$.IndexInfo(Ts.FullTbName, NULL) For XML Raw, type)) as DropIndexes
  , f$.ConcatInfoFromXML(0, '',  (Select AddForeignKey From f$.ForeignKeyInfoByTable(Ts.FullTbName) For XML Raw, type)) as AddForeignKeys
  , f$.ConcatInfoFromXML(0, '',  (Select DropForeignKey From f$.ForeignKeyInfoByTable(Ts.FullTbName) For XML Raw, type)) as DropForeignKeys
  , f$.ConcatInfoFromXML(0, '',  (Select AddFullTextIndex From f$.FullTextInfo(Ts.FullTbName) For XML Raw, type)) as AddFullTextIndexes
  , f$.ConcatInfoFromXML(0, '',  (Select DropFullTextIndex From f$.FullTextInfo(Ts.FullTbName) For XML Raw, type)) as DropFullTextIndexes
  , principal_id, schema_id, parent_object_id, type, type_desc, create_date, modify_date
  , is_ms_shipped, is_published, is_schema_published, lob_data_space_id, filestream_data_space_id
  , max_column_id_used, lock_on_bulk_load, uses_ansi_nulls, is_replicated, has_replication_filter
  , is_merge_published, is_sync_tran_subscribed, has_unchecked_assembly_data, text_in_row_limit
  , large_value_types_out_of_row, is_tracked_by_cdc, lock_escalation, lock_escalation_desc, is_filetable
  From 
    TabLevelInfoAndTabLevelAction Ts
  )
, TemplateCreate As
  (
  Select
    '
    Create Table #FullTbName#
    (
    #Cols#
    )
    ' as sql
  )
Select MTC.*, r1.s as CreateTableWithColsWithConstraintName, r2.s as CreateTableWithColsWithoutConstraintName
From 
  MostTableComponents MTC
  CROSS JOIN TemplateCreate tmp
  CROSS APPLY  f$.iReplace(tmp.sql, '#FullTbName#', MTC.FullTbName) as r0
  CROSS APPLY  f$.iQReplace(r0.s, '#Cols#', MTC.ColsDefAndCN) as r1
  CROSS APPLY  f$.iQReplace(r0.s, '#Cols#', MTC.ColsDef) as r2

-- Select T.* into #tmp from f$.TableInfo(NULL) as T; select * from #tmp  Order by FullTbName; drop table #tmp  -- if read directly to client takes much more time to process
-- Select T.* from f$.TableInfo('[dbo].[gpm_e_ele]') as T Order by T.FullTbName
-- Select T.* From f$.TableInfo('[dbo].[GPM_E_COMMUNICATION]') as T Order by T.FullTbName
-- Select T.* from Sys.Tables s Cross apply f$.TableInfo(f$.FullObjName(T.object_id)) as T Where f$.name like '%ELE%' order by T.FullTbName
-- Select T.* from Sys.Tables s Cross apply f$.TableInfo(f$.FullObjName(T.object_id)) as T order by T.FullTbName
)
GO

-- ---------------------------------------------------------------------------------------------------------------------
-- Function that put alias specified in parameter in from of each colum of a list
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.TableColsAliased'
GO
--f$SignatureForCleanup
Create Function f$.TableColsAliased (@Tab sysname, @Alias sysname)
Returns Table
as
Return
(
Select 
  f$.AdjConcatRS
  (
    ','
  , (
    Select f$.CMax(',' + @Alias+'.'+Quotename(F.cn)) AS [text()] 
    From f$.ColInfo (f$.FullObjName(object_id(@Tab)), NULL) as F
    Order by F.ColOrd 
    For XML PATH('')
    )
  ) as ListeCol
)
-- Select * from f$.TableColsAliased('[dbo].[gpm_e_ele]', 'E')
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function add/replace alias to a given column.  Useful when generating SQL Queries
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ReplaceAnyAlias'
GO
--f$SignatureForCleanup
Create Function f$.ReplaceAnyAlias (@col sysname, @Alias sysname)
Returns sysname
as
Begin
  If charindex('.', @col) > 0
    Set @Col = Stuff(@col, 1, charindex('.', @col), '');
  If @Alias <> '' Set @Alias = @Alias + '.'
  Return (@Alias+@Col)
End
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function to put alias on a given column list (useful when generating queries)
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.PutAliasesOnColList'
GO
--f$SignatureForCleanup
Create Function f$.PutAliasesOnColList (@SrcColList nvarchar(Max), @Alias sysname) 
Returns Nvarchar(max)
as
Begin
  Return
  (
    Select
      f$.AdjConcatRS
      (
        ','
      , (
        Select f$.CMax (','+@ALias+'.'+L.item) as [text()] 
        From f$.SplitList (',', @SrcColList) as L
        Order By L.seq 
        For XML Path('')
        )
      )
  )
-- Select f$.PutAliasesOnColList(' fiche, org', 'f$')
End
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function to build template from single list values
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.BuildTemplateFromSimpleList'
GO
--f$SignatureForCleanup
Create Function f$.BuildTemplateFromSimpleList (@itemListTag nvarchar(max), @tempColList nvarchar(Max), @firstItemToRemove nvarchar(max), @SrcColList nvarchar(Max)) 
Returns Table
as
Return
(
  Select
    f$.AdjConcatRS
    ( 
      @firstItemToRemove
    , (
      Select f$.Cmax(s) as [text()]
      From
        f$.SplitList(',', @SrcColList) as L
        Cross Apply f$.iReplace (@tempColList, @itemListTag, L.item)
      Where IsNull(L.item, '') <> ''
      Order by L.Seq
      For XML PATH('')
      )
    ) as s
)
--select * From f$.BuildTemplateFromSimpleList('#col#', 'And A.#col# = B.#col# ', 'and ', 'col1, col2, col3, col4, col5')
-- select *, len(s) From f$.BuildTemplateFromSimpleList('#col#', 'And A.#col# = B.#col# ', 'and ', NULL)
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function to build template from column list
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.BuildTemplateFromColList'
GO
--f$SignatureForCleanup
Create Function f$.BuildTemplateFromColList (@tempColList nvarchar(Max), @firstItemToRemove nvarchar(max), @SrcColList nvarchar(Max)) 
Returns Table
as
Return
(
  Select * From f$.BuildTemplateFromSimpleList('#col#', @tempColList, @firstItemToRemove, @SrcColList)
)
--select * From f$.BuildTemplateFromColList('And A.#col# = B.#col# ', 'and ', 'col1, col2, col3, col4, col5')
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function to build template from list pairs
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.BuildTemplateTwoMatchingList'
GO
--f$SignatureForCleanup
Create Function f$.BuildTemplateTwoMatchingList (@ListTags nvarchar(max), @tempColList nvarchar(Max), @firstItemToRemove nvarchar(max), @lColList nvarchar(Max), @RColList nvarchar(Max)) 
Returns Table
as
Return
(
  With 
    LeftAndRightTags as 
    (
    Select Max(Case When L.Seq = 1 Then L.item Else '' End) as lTag, Max(Case When L.Seq = 2 Then L.item Else '' End) as rTag
    From f$.SplitList(',', @ListTags) L
    )
  Select
    f$.AdjConcatRS
    ( 
      @firstItemToRemove
    , (
      Select f$.Cmax(r1.s) as [text()]
      From
        f$.SplitList(',', @LColList) as L1
        CROSS APPLY f$.SplitList(',', @RColList) as L2
        Cross Apply f$.iReplace (@tempColList, t.ltag, L1.item) as r0
        Cross Apply f$.iReplace (r0.s, t.rtag, L2.item) as r1
      Where L1.seq = L2.seq 
        And IsNull(L1.item, '') <> ''
        And IsNull(L2.item, '') <> ''
      Order by L1.Seq
      For XML PATH('')
      )
    ) as s
  From 
    LeftAndRightTags T
)
--select * From f$.BuildTemplateFromListPairs('#lcol#, #Rcol#', 'And A.#lcol# = B.#rcol# ', 'and ', 'CODE_PMNT, NO_CMPT', 'CODE_PMNT2, NO_CMPT2')
--select * From f$.BuildTemplateFromListPairs('#lcol#, #Rcol#', 'And A.#lcol# = B.#rcol# ', 'and ', 'CODE_PMNT, NO_CMPT', NULL)
GO
-- ---------------------------------------------------------------------------------------------------------------------
-- Function to build template from column list pair, useful if pairs of the list doesn't have the same name as in joins
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.BuildTemplateFromTwoMatchingColsList'
GO
--f$SignatureForCleanup
Create Function f$.BuildTemplateFromTwoMatchingColsList (@tempColList nvarchar(Max), @firstItemToRemove nvarchar(max), @lColList nvarchar(Max), @RColList nvarchar(Max)) 
Returns Table
as
Return
(
  select * From f$.BuildTemplateTwoMatchingList('#lcol#, #Rcol#', @tempColList, @firstItemToRemove, @lColList, @RColList)
)
--select * From f$.BuildTemplateFromTwoMatchingColList('And A.#lcol# = B.#rcol# ', 'and ', 'CODE_PMNT, NO_CMPT', 'CODE_PMNT2, NO_CMPT2')
GO

-- ---------------------------------------------------------------------------------------------------------------------
-- Function to build template from column pair list ex: ('and #lcol# = #rcol# ', 'and ', 'col1|Nouvcol1, col2|Nouvcol2, col3|Nouvcol3, col4|Nouvcol4, col5|Nouvcol5')
-- where first parameter is the template, and is the first item to remove in the generated code, and the list
-- are individual pairs in which the '|' char separate #lcol# value from #rCol# value
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.BuildTemplateFromColPairList'
GO
--f$SignatureForCleanup
Create Function f$.BuildTemplateFromColPairList (@tempColList nvarchar(Max), @firstItemToRemove nvarchar(max), @ColPairList nvarchar(Max)) 
Returns Table
as
Return
(
  With Params as
  (
    Select @tempColList as tempColList, @firstItemToRemove as firstItemToRemove, @ColPairList as ColPairList
  )

  Select
    f$.AdjConcatRS
    ( 
      Params.firstItemToRemove
    , (
      Select f$.Cmax(r1.s) as [text()]
      From
        f$.SelFromPairList (NULL, ',|', Params.ColPairList) Pairs
       Cross Apply f$.iReplace (Params.tempColList, '#lcol#', Pairs.item1) as r0      
       Cross Apply f$.iReplace (r0.s, '#rcol#', Pairs.item2) as r1      
      Where IsNull(Pairs.item1, '') <> ''
        And IsNull(Pairs.item2, '') <> ''
      Order by Pairs.seq
      For XML PATH('')
      )
    ) as s
  From
    Params

)
--select * From f$.BuildTemplateFromColPairList('and #lcol# = #rcol# ', 'and ', 'col1|Nouvcol1, col2|Nouvcol2, col3|Nouvcol3, col4|Nouvcol4, col5|Nouvcol5')
--select * From f$.BuildTemplateFromColPairList('and #lcol# = #rcol# ', 'and ', 'col1')
--select * From f$.BuildTemplateFromColPairList('and #lcol# = #rcol# ', 'and ', 'col1|')
--select * From f$.BuildTemplateFromColPairList('and #lcol# = #rcol# ', 'and ', '|')
--select * From f$.BuildTemplateFromColPairList('and #lcol# = #rcol# ', 'and ', '')
--select * From f$.BuildTemplateFromColPairList('and #lcol# = #rcol# ', 'and ', NULL)
GO

-- ---------------------------------------------------------------------------------------------------------------------
-- Function to replace columns in a column list, by supplying columns pair replacements.
-- ---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.ReplaceColsList'
GO
--f$SignatureForCleanup
Create Function f$.ReplaceColsList (@SrcColList nvarchar(Max), @Replaces nvarchar(Max)) 
Returns Nvarchar(max)
as
Begin
  Declare @newVal nvarchar(max)
  declare @nbRep Int
  declare @iRep Int
  declare @tbRepl Table (seq int, fromCol sysname, toCol sysname)
  Insert @tbRepl
  Select A.Seq, Min(B.Item), Max(B.Item)
  From 
    f$.SplitList(',', @Replaces) A
    Cross Apply f$.SplitList('|', A.Item) B
  Group by A.Seq
  Select @nbRep = @@rowcount
  Set @iRep = 1
  While(@iRep <= @nbRep)
  Begin
    Select @SrcColList = Replace (@SrcColList, fromCol, toCol)
    From @tbRepl 
    Where seq = @iRep
    Set @iRep = @iRep +1
  End
  Return (@SrcColList)
End
GO
----------------------------------------------------------------------------------------------------------------------
-- Cette procédure met le caractère '\' devant les caractères spéciaux "[" "]" et "_" des noms de tables
-- Tous ces caractères sont "escapés" si le second paramètre est pas complété, sinon ça se limite à ceux spécifiés.
--
Exec f$.DropObj 'f$.EscapeObjNameSpecialChars'
GO
--f$SignatureForCleanup
Create Function f$.EscapeObjNameSpecialChars (@n nvarchar(max), @carToEscape nvarchar(3), @escapeChar nchar(1)) 
Returns Nvarchar(max)
as
Begin
  Declare @ret nvarchar(max)
  ;With CharToEscape as (Select @n as NomSrc, ISNULL(@cartoEscape, '[]_') as chrs) 
  Select @ret=r2.s
  From 
    CharToEscape
    Cross Apply f$.iReplace(NomSrc,  Substring(chrs, 1, 1), ISNULL(@escapeChar, '\')+Substring(chrs, 1, 1)) as r0
    Cross Apply f$.iReplace(r0.s,  Substring(chrs, 2, 1), ISNULL(@escapeChar, '\')+Substring(chrs, 2, 1)) as r1
    Cross Apply f$.iReplace(r1.s,  Substring(chrs, 3, 1), ISNULL(@escapeChar, '\')+Substring(chrs, 3, 1)) as r2
  Return(@ret)
  /*
  ;With 
    EscapesTest As
    (
    Select 
      f$.EscapeObjNameSpecialChars('[dbo].[gpm_e_ele]', NULL, '\') as EscWithUAndB
    , f$.EscapeObjNameSpecialChars('dbo.gpm_e_ele', '_', '\') as EscWithUOnly
    , '[dbo].[gpm_e_ele]' as tbNameWithUAndB
    , 'dbo.gpm_e_ele' as tbNameWithUOnly
    )
  Select tbNameWithUAndB, EscWithUAndB, case When tbNameWithUAndB like EscWithUAndB Escape '\' Then 'Match' Else 'noMatch' End From EscapesTest
  UNION ALL
  Select tbNameWithUOnly, EscWithUOnly, case When tbNameWithUOnly like EscWithUOnly Escape '\' Then 'Match' Else 'noMatch' End From EscapesTest
  UNION ALL
  Select tbNameWithUOnly, EscWithUAndB, case When tbNameWithUOnly like EscWithUAndB Escape '\' Then 'Match' Else 'noMatch' End From EscapesTest
  UNION ALL
  Select tbNameWithUAndB, EscWithUOnly,case When tbNameWithUAndB like EscWithUOnly Escape '\' Then 'Match' Else 'noMatch' End From  EscapesTest
  */
End
GO
---------------------------------------------------------------------------------------------------------------------
-- This function applies multiple like filters. The first parameter is the value to be tested against match list
-- and not match list. Empty match list accept the value otherwise value must match with one of the possible likes.
-- Empty no match list, does not restrict result.  A no match list reject value accept by at leat one match list,
-- if any of the no match list fits with the value
---------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.MatchByLikeListAndReduceByNotLikeList'
GO
--f$SignatureForCleanup
Create Function f$.MatchByLikeListAndReduceByNotLikeList (@val nvarchar(max), @MatchList nvarchar(max), @NoMatchListOverMatches nvarchar(max))
Returns Table
as
Return
(
with 
  Prm as 
  (
  Select 
    @val as Val
  , f$.EscapeObjNameSpecialChars(ISNULL(@MatchList,'%'), NULL, '\') as MatchList
  , f$.EscapeObjNameSpecialChars(ISNULL(@NoMatchListOverMatches, ''), NULL, '\')  as NoMatchListOverMatches 
  )
, MatchesFiltered as 
  (
  select Top 1 Prm.Val, Prm.NoMatchListOverMatches 
  From 
    Prm 
    Cross Apply f$.SplitList(',', Prm.MatchList) L 
  Where Prm.Val like L.item Escape '\'
  )
, AppliedNoMatchesOverAlreadyMatched as 
  (
  select Top 1 MatchesFiltered.Val 
  From 
    MatchesFiltered 
    Cross Apply f$.SplitList(',', MatchesFiltered.NoMatchListOverMatches) L 
  Where MatchesFiltered.Val like L.item Escape '\'
  ) 
Select val from MatchesFiltered  -- those first found in match list
EXCEPT
Select val from AppliedNoMatchesOverAlreadyMatched -- those among first found that match remove list
/*  Some tests
;with vals as (select * from (values ('dbo.z_tt'), ('dbo.z_at'), ('dbo.z_ab'), ('dbo.z_zt'), ('dbo.e_tt'), ('dbo.e_zt')) t(n))
Select Val From Vals Cross Apply f$.MatchByLikeListAndReduceByNotLikeList(n, 'dbo.z%,dbo.e%', 'dbo.z%z%,dbo.e%z%,%b')
;with vals as (select * from (values ('dbo.z_tt'), ('dbo.z_at'), ('dbo.z_ab'), ('dbo.z_zt'), ('dbo.e_tt'), ('dbo.e_zt')) t(n))
Select Val From Vals Cross Apply f$.MatchByLikeListAndReduceByNotLikeList(n, 'dbo.e%', NULL)
;with vals as (select * from (values ('dbo.z_tt'), ('dbo.z_at'), ('dbo.z_ab'), ('dbo.z_zt'), ('dbo.e_tt'), ('dbo.e_zt')) t(n))
Select Val From Vals Cross Apply f$.MatchByLikeListAndReduceByNotLikeList(n, NULL, 'dbo.z%z%,dbo.e%z%,%b')
;with vals as (select * from (values ('dbo.z_tt'), ('dbo.z_at'), ('dbo.z_ab'), ('dbo.z_zt'), ('dbo.e_tt'), ('dbo.e_zt')) t(n))
Select Val From Vals Cross Apply f$.MatchByLikeListAndReduceByNotLikeList(n, 'dbo.z%,dbo.e%', 'dbo.z%z%,dbo.e%z%,%b')
;with vals as (select * from (values ('dbo.z_tt'), ('dbo.z_at'), ('dbo.z_ab'), ('dbo.z_zt'), ('dbo.e_tt'), ('dbo.e_zt')) t(n))
Select Val From Vals Cross Apply f$.MatchByLikeListAndReduceByNotLikeList(n, '[dbo].e%', '')
;with vals as (select * from (values ('[dbo].[z_tt]'), ('[dbo].[z_at]'), ('[dbo].[z_ab]'), ('[dbo].[z_zt]'), ('[dbo].[e_tt]'), ('[dbo].[e_zt]')) t(n))
Select Val From Vals Cross Apply f$.MatchByLikeListAndReduceByNotLikeList(n, '%', '[dbo].[z_z%],[dbo].[e_z%],%b]')
*/
)
GO
Exec f$.DropObj 'f$.DropRecreateWithReplaces'
GO
--f$SignatureForCleanup
Create Function f$.DropRecreateWithReplaces(@CodeTag sysname, @ObjDef nvarchar(max), @XmlAttForReplaces XML)
Returns table  -- the xml attribute FullObjName is expected in @XmlAttForReplaces 
as
Return
(
With 
  Prm as 
  (
  Select 
    @XmlAttForReplaces as XmlAttForReplaces
  , @CodeTag as CodeTag
  , @ObjDef as ObjDef

  --  /*CodeTag
  --  create table #fullobjName# (i int)
  --  CodeTag*/
  --  (Select 'toto' as FullObjName For XML Raw, type) as XmlAttForReplaces
  --, 'CodeTag' as CodeTag
  --, null as ObjDef
  )
  --Select * from Prm
, PrmDef as 
  (
  Select 
    ISNULL(XmlAttForReplaces, (Select CodeTag AS FullObjName For XML RAW, TYPE)) as XmlAttForReplaces
  , Case When XmlAttForReplaces IS NULL Then CodeTag Else XmlAttForReplaces.value('row[1]/@FullObjName', 'sysname') End as FullObjName
  , CodeTag
  , ObjDef
  From 
    Prm
  )
  --Select * from PrmDef
, PrmDef2 as 
  (
  select 
    XmlAttForReplaces
  , FullObjName
  , ObjDef
  , CodeTag
  From PrmDef
  Where ObjDef IS NOT NULL -- take ObjDef preferably when it is not null
  UNION ALL
  select 
    XmlAttForReplaces as XmlAttForReplaces
  , FullObjName
  , B.BatchComment as ObjDef
  , CodeTag
  From 
    PrmDef
    Cross Apply f$.GetCommentFromBatch(CodeTag) as B 
  Where ObjDef IS NULL And CodeTag IS NOT NULL  -- take code from f$.GetCommentFromBatch If @CodeTag is supply and ObjDef is not supplied
  )
  --Select * From PrmDef2
, DropCreate as
  (
  Select 'Exec f$.DropObj ''#FullObjName#''' as sql, 1 as seq, FullObjName, XmlAttForReplaces 
  From PrmDef2
  Where FullObjName IS not null
  UNION ALL
  Select ObjDef as Sql, 2 as seq, FullObjName, XmlAttForReplaces 
  From PrmDef2
  Where FullObjName IS not null
  UNION ALL
  Select 'Raiserror ("The attribute FullObjName must be present in xml attributes of XmlAttForReplaces parameter or through @codeTag Parameter",11,1)' as Sql, 1 as seq, FullObjName, XmlAttForReplaces 
  From PrmDef2
  Where FullObjName IS null
  )
  --Select * From DropCreate
Select r.finalReplace as Sql, Row_number() Over (Order By D.FullObjName, D.seq) as Seq, D.FullObjName, D.XmlAttForReplaces
From 
  DropCreate D
  Cross Apply f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(D.Sql, D.XmlAttForReplaces) as R
/*

Select 
  R.Sql, row_number() Over(Order by R.FullObjName, R.Seq) as seq
From 
  sys.Procedures P
  Cross apply f$.DropRecreateWithReplaces (null, Object_definition(P.Object_id), (Select f$.FullObjName(P.Object_id) as FullObjName  For XML Raw, type)) as R

/*GricsDw.VuesAx
create view GricsDw.VuesAx as 
Select 
  f$.FullObjName(object_id) as FullViewName
, OBJECT_DEFINITION(Object_id) as ViewDef
, Object_id as ViewId
From sys.views 
Where Name Like 'GricsEntr%'
GricsDw.VuesAx*/
Select 
  D.sql, D.Seq 
From 
  f$.DropRecreateWithReplaces('GricsDw.VuesAx', NULL, NULL) as D


*/
)
GO
Exec f$.DropObj 'f$.FindDataInXML'
GO
--------------------------------------------------------------------------------------------------------------------------------------
-- Function that test occurence of a given column in XML row, in which column is expressed as an XML attribute of the <row> document
-- if column is non existent it returns no row. It is used by f$.ScriptRowContentBuilder
--------------------------------------------------------------------------------------------------------------------------------------
--f$SignatureForCleanup
Create Function f$.FindDataInXML (@txt nvarchar(max), @cn sysname, @typ sysname)
returns table
as
Return
(
With 
  prm as 
  (
  select 
    @txt as Txt
  , @cn as Cn
  , @typ as Typ
  , ' '+@Cn+'="' as ColSearchExpr
  )
, NonNullColumns as -- find cols that have h
  (
  Select *, Charindex(ColSearchExpr, txt) as ColPosInXml
  From 
    Prm 
  Where Charindex(ColSearchExpr, txt) > 1
  )
  --Select * From ColsHavingValues
, ColsStartingAndEndingPos as 
  (
  Select 
    *
  , ColPosInXml+Len(ColSearchExpr) as StartDataPos
  , charindex('"', txt, ColPosInXml+Len(ColSearchExpr)) as EndDataPos
  From 
    NonNullColumns
  )
  --Select * From ColsStartingAndEndingPos
, DataInXml as
  (
  Select C.*, Case When typ <> 'varbinary' Then Q.s Else convert(nvarchar(max), CAST(N'' AS xml).value('xs:base64Binary(sql:column("Q.s"))', 'varbinary(max)'), 1) End as Data 
  From 
    ColsStartingAndEndingPos as C
    CROSS APPLY f$.CleanXmlText(Substring (txt, StartDataPos, EndDataPos-StartDataPos)) as T    
    CROSS APPLY f$.iReplace(T.s, '''', '''''') as Q
  )
Select * From DataInXml
--select * From f$.FindDataInXML('<row eq="ABA=" a="ABA=" b="IA==" />>', 'a', 'varbinary')
)
GO
Exec f$.DropObj 'f$.ScriptPrmPersistenceForSp'
GO
----------------------------------------------------------------------------------------------------
-- This procedure is an helper procedure to generate a select (from sp parameters) into #Prm table
-- Using a #Prm table make easier to test code parts in stored procedure since we use this #Prm table
-- as a persisted source or paramters in functional programming
-- It generated also a commented version that makes easy to substitute parameter values without
-- relying on parameter declaration to run it
----------------------------------------------------------------------------------------------------
--f$SignatureForCleanup
Create Proc f$.ScriptPrmPersistenceForSp @Prcname sysname
as
Begin
;With 
  SyntaxElements as
  (
  select 
    ForTestTemplate.s as ColForTestTemplate
  , ForRealPrm.s as ColForRealPrm
  from 
    sys.parameters as P
    Cross Apply f$.GetDataTypeExpressionElements(P.user_type_id, P.system_type_id, P.max_length, P.precision, P.scale, 0, P.is_xml_document, NULL) as T
    Cross Apply f$.iReplace('CAST (#StartQuote#NULL#EndQuote# As #TypeSpec#) as #Cn#', '#typeSpec#', T.TypeSpec) as r0
    Cross Apply f$.iReplace(r0.s, '#cn#', stuff(name, 1, 1, '')) as r1
    Cross Apply f$.iReplace(r1.s, '#StartQuote#', T.startQuote) as r2
    Cross Apply f$.iReplace(r2.s, '#EndQuote#', T.EndQuote) as r3
    Cross Apply f$.iReplace(r3.s, 'N''NULL', 'N''') as r4
    Cross Apply f$.iReplace(r4.s, '''NULL', '''') as r5
    Cross Apply f$.iReplace(r5.s, '0xNULL', '0x') as ForTestTemplate
    Cross Apply f$.iReplace('@#Cn# as #Cn#', '#cn#', stuff(name, 1, 1, '')) as ForRealPrm
  where object_id = object_id(@PrcName) 
  )
, ColsForInto as
  (
  /*===MakeSelectIntoTmp===
  If Object_id('Tempdb..#Prm') IS NOT NULL Drop table #Prm
  Select #ColsForRealPrm# Into #Prm
  --This commented sample below makes easy to create a #Prm table to test sp parts.
  --Select #ColsForTestTemplate# Into #Prm
  ===MakeSelectIntoTmp===*/
  Select R1.s as PersistPrm
  From 
    f$.GetCommentFromBatch ('===MakeSelectIntoTmp===') as B
    CROSS JOIN
    f$.ApplyConcatInfoFromXML(1, ',', (Select ColForTestTemplate From SyntaxElements For Xml Raw, type)) as CT
    Cross JOIN
    f$.ApplyConcatInfoFromXML(1, ',', (Select ColForRealPrm From SyntaxElements For Xml Raw, type)) as CR
    Cross Apply f$.iReplace (B.BatchComment, '#ColsForTestTemplate#', CT.Res) as r0
    Cross Apply f$.iReplace (r0.s, '#ColsForRealPrm#', CR.Res) as r1
  )
 Select L.Line
 from 
   ColsForInto
   Cross Apply f$.SplitSqlCodeInRowLines (ColsForInto.PersistPrm) as L
 Order By L.LineNum
End --  Exec f$.ScriptPrmPersistenceForSp 'M.SetParametresEnvironnement'
GO                                       
EXEC f$.DropObj 'f$.ScriptRowContentBuilderMode';
GO
--------------------------------------------------------------------------------------------------------------------------------------
-- Function that express enums that are used as parameters to f$.ScriptRowContentBuilder and tested by it.
--------------------------------------------------------------------------------------------------------------------------------------
--f$SignatureForCleanup
Create Function f$.ScriptRowContentBuilderMode () 
Returns Table 
as 
Return
(
Select 
  'InsertSelectWithColAliases' as InsertSelectWithColAliases
, 'InsertWithSimpleValueList' as InsertWithSimpleValueList
, 'CsvRows' as CsvRows
, 'RowConstructor' as RowConstructor
) 
GO
Exec f$.DropObj 'f$.ScriptRowContentBuilder'
GO
--f$SignatureForCleanup
Create Function f$.ScriptRowContentBuilder (@destTb Sysname, @SrcQuery nvarchar(max), @OrderByClause nvarchar(max), @SaveDataLogicMode sysname)
returns table 
as
Return
(
/*RowContentBuilder
  Set nocount on
  ;With GetSchemaInfo as (#SrcQuery#) Select Top 0 * Into #InferSchemaInfo From GetSchemaInfo;

   --make a decision table based on datatype name pattern matching to find out proper quoting of columns by types
  ;With 
    LikeOftypesToQuote as 
    (
    Select *
    From (Values ('[N]%char', 'N''', ''''),('[VC]%har', '''', ''''),('%date%', '''', ''''),('time%', '''', ''''),('XML','''','''')) as T(typeLike, startQuote, EndQuote)
    )
  select 
      Name as Cn
    , column_id as ColOrd
    , type_name(system_type_id)  as typ
    , ISNULL(L.startQuote, '') as startQuote, ISNULL(L.EndQuote, '') as EndQuote
  INTO #TmpColInfo
  From 
    tempdb.sys.columns 
    LEFT JOIN LikeOftypesToQuote L
    ON type_name(system_type_id) Like L.typeLike
  Where object_id = object_id('tempdb..#InferSchemaInfo') -- get info from the new temporary table that infer columns and type issued from source query 

  ;With 
    PrmMode as 
    (
    Select '#SaveDataLogicMode#' as currentMode, Modes.* From f$.ScriptRowContentBuilderMode() as Modes 
    )
  , ColInfos as -- Get col information 
    (
    Select CI.startQuote, CI.EndQuote, CI.cn, CI.ColOrd, CI.typ
    From  #TmpColInfo CI
    )
    --Select * From ColInfos
  , Datasource as (#SrcQuery#) -- Get data source
    --Select * from Datasource
  , SomeXmlDoc as -- make an XML version of rows, and convert them into Nvarchar(max)
    (
    Select 
      convert
      ( nvarchar(max)
      , (
        SELECT 
          (
          Select D.* 
          for XML raw, TYPE, BINARY BASE64
          ) as RowContent
        ) 
      ) as XmlTxtWithEscapesInData
    , Row_Number() Over (#orderByClause#)  as rowSeq
    From 
      Datasource as D
    )
  , ColsAndValuesList As -- build column list for insert and different value list expressions
    (
    Select 
      P.*
    , D.rowSeq
    , f$.AdjConcatRS
      (
        ', '
      , ( -- concat columns names for which data exists
        Select f$.CMax(', '+ISNULL(CI.cn, 'NULL')) as [text()]
        From 
          ColInfos CI
        Order By CI.colOrd
        For XML PATH('')
        ) 
      ) as ColList

   , f$.AdjConcatRS
      (
        ', '
      , ( -- concat existing values to express the equivalent of a csv row
        Select f$.CMax(', '+ISNULL(CI.StartQuote+CD.Data+CI.EndQuote, 'NULL')) as [text()]
        From 
          ColInfos CI
          OUTER APPLY f$.FindDataInXML (D.XmlTxtWithEscapesInData, CI.cn, CI.Typ) CD
        Order By CI.colOrd
        For XML PATH('')
        ) 
      )  as CsvRow

    , f$.AdjConcatRS
      (
        ', '
      , ( -- concat existing values to express an select in which data goes with columns aliases 
        Select f$.CMax(', '+ISNULL(CI.StartQuote+CD.Data+CI.EndQuote, 'NULL')+' as '+CI.Cn) as [text()]
        From 
          ColInfos CI
          OUTER APPLY f$.FindDataInXML (D.XmlTxtWithEscapesInData, CI.cn, CI.typ) CD
        Order By CI.colOrd
        For XML PATH('')
        ) 
      ) as ColsValuesAsSelectWithAliases

    , Case When Not Exists(Select * From SomeXmlDoc) Then 'top(0)' Else '' End as DoEmptyResultSet
    From 
      PrmMode as P
      LEFT JOIN SomeXmlDoc as D ON (1=1) -- at least one row if nothing
    )
    --Select * From ColsAndValuesList 
  , SaveDataLogicBuiltFromTemplate as 
    (
    Select 
      CV.*, CV.CsvRow as sql
    From ColsAndValuesList as CV
    Where CV.currentMode IN (CV.CsvRows, CV.RowConstructor)

    UNION ALL
    Select CV.*, 'Insert into #DestTb# (#cols#) Select #DoEmptyResultSet# '+CV.ColsValuesAsSelectWithAliases as Sql
    From 
      ColsAndValuesList as CV
    Where CV.currentMode IN (CV.InsertSelectWithColAliases)

    UNION ALL
    Select CV.*, 'Insert #DoEmptyResultSet# into #DestTb# (#cols#) Values('+CV.CsvRow+')' as Sql
    From ColsAndValuesList as CV
    Where CV.currentMode IN (CV.InsertWithSimpleValueList)
    )
  , ExternalElementsOfSelectFromRowConstructor (StartSyntax, EndSyntax) As
    (
    Select 
'Select #DoEmptyResultSet# #Cols# 
From 
  (
  Values
' as StartSyntax
, 
 ') as T(#Cols#) ' as EndSyntax
    )
  , SaveDataLogic As
    (
    -- for generating CsvRows, InsertSelectWithColAliases, InsertWithSimpleValueList
    Select  
      0 as syntaxSeq, S.RowSeq, S.ColList, S.DoEmptyResultSet
    , S.Sql
    From 
      SaveDataLogicBuiltFromTemplate as S
    Where  
      S.currentMode IN (S.CsvRows, S.InsertSelectWithColAliases, S.InsertWithSimpleValueList)
    UNION ALL

    -- for generating RowConstructor
    Select  
      TOP (1) 0 as syntaxSeq, 0 as rowSeq, S.ColList, S.DoEmptyResultSet, ExternalElementsOfSelectFromRowConstructor.StartSyntax as Sql
    From 
      ExternalElementsOfSelectFromRowConstructor
      CROSS JOIN 
      SaveDataLogicBuiltFromTemplate as S
    Where S.currentMode = S.RowConstructor
    UNION ALL
    Select  -- middle syntax
      1 as syntaxSeq, S.rowSeq, S.ColList, S.DoEmptyResultSet
    , Case When S.rowSeq > 1 Then '  ,' Else  '   ' End +  ' ('+ S.CsvRow + ')' as Sql
    From 
      SaveDataLogicBuiltFromTemplate as S
    Where S.currentMode = S.RowConstructor
    UNION ALL
    Select
      TOP (1) 2 as syntaxSeq, rowSeq, S.ColList, S.DoEmptyResultSet, ExternalElementsOfSelectFromRowConstructor.EndSyntax as Sql
    From 
      ExternalElementsOfSelectFromRowConstructor
      CROSS JOIN 
      SaveDataLogicBuiltFromTemplate as S
    Where S.currentMode = S.RowConstructor
    )
  Select r2.s
  From 
    SaveDataLogic S
    CROSS APPLY f$.iQReplace (S.Sql, '#DoEmptyResultSet#', S.DoEmptyResultSet ) as r1
    CROSS APPLY f$.iReplace (r1.s, '#Cols#', Stuff(S.ColList, 1, 2, '')) as r2
  Order By S.syntaxSeq, S.RowSeq   
RowContentBuilder*/
--Insert into @qry (qry, seq) -- a table function must be used otherwise f$.GetCommentFromBatch doesn't see the internal comment
Select r3.s as SqlBatch, 1 as seq
From 
  f$.GetDelimitedCommentFromText (OBJECT_DEFINITION(object_id('f$.ScriptRowContentBuilder')), 'RowContentBuilder', 'f$.ScriptRowContentBuilder') as SqlTemplate
  Cross Apply f$.iQReplace(SqlTemplate.CommentContent, '#DestTb#', @destTb) as r0
  Cross Apply f$.iReplace(r0.s, '#SrcQuery#', @SrcQuery) as r1
  Cross Apply f$.iReplace(r1.s, '#orderByClause#', @OrderByClause) as r2
  Cross Apply f$.iReplace(r2.s, '#SaveDataLogicMode#', @SaveDataLogicMode) as r3
/*
exec f$.DropObj 'dbo.destTable'
create table dbo.destTable (ca nvarchar(20), cb int,       cx varbinary(max), cd datetime, ct time, testNull nvarchar(5))
insert into dbo.destTable values ('donneeA', 1,  0x10130022,         '20201212',   '10:20:30', 'he')
insert into dbo.destTable values ('donneeB', 2,  0x000001, '20211212',   '20:20:30', null)
Insert into f$.ScriptToRun (sql, seq)
Select M.*
From 
  f$.ScriptRowContentBuilderMode() as Mode  -- this function allows to get comment content
  CROSS APPLY f$.ScriptRowContentBuilder ('destTable2', 'Select top 10 * From dbo.destTable where ca like ''don%''', 'Order by ca', Mode.RowConstructor) M
Exec f$.RunScript @Silent=0
declare @sqlBatch nvarchar(max) 
Select @sqlBatch = M.SqlBatch
From 
  f$.ScriptRowContentBuilderMode() as Mode
  CROSS APPLY f$.ScriptRowContentBuilder ('destTable', 'Select top 10 * From dbo.destTable where ca like ''don%''', 'Order by ca', Mode.InsertWithSimpleValueList) M
Exec (@sqlBatch)
*/
)
GO
Exec f$.DropObj 'f$.ScriptCompareRows'
GO
--f$SignatureForCleanup
Create Function f$.ScriptCompareRows (@TQryTag nvarchar(max), @RQryTag nvarchar(max))
Returns Table
as
Return
( 
/*  -- this comment is for testing by selecting the code inside of the function and running
/*CodeIsSelectedForRun1_True_CodeIsSelectedForRun*/
/*T select * From sys.tables T*/
/*R select * From sys.tables where name not like '%test%' R*/
Insert into f$.QueryToRun (Sql, seq) Select * From f$.ScriptCompareRows ('T', 'R')
Exec f$.RunQuery
*/

/*f$.ScriptCompareRowsTemplate

    Exec f$.DropObj 'f$.tmp#spid#', @silent=1

    ;With 
      SelInto as
      (
      Select '#TQryTag#' as idRsToCompare, * From (#TQry#) as T
      UNION ALL
      Select '#RQryTag#' as idRsToCompare, * From (#RQry#) as T
      )
    Select *
    Into f$.tmp#spid# 
    From SelInto

    Declare @collist nvarchar(max)
    Select @collist = 
    (
    Select f$.CMax(','+name) as [text()] 
    from sys.columns 
    where object_id = Object_id('f$.tmp#spid#') and name <> 'idRsToCompare' 
    Order by column_id For XML Path('')
    )
    Set @collist = Stuff(@colList, 1, 1, '')

    Declare @sql nvarchar(max) =
    '
    ;With 
       Compare as
       (
       Select 
         Min(idRsToCompare) Over (Partition by #colList#) as MinIdRsToCompare
       , Max(idRsToCompare) Over (Partition by #colList#) as MaxIdRsToCompare
       , *
       From 
         f$.tmp#spid#
       )
    Select MaxIdRsToCompare as rowSource,  #colList#
    From Compare 
    Where MinIdRsToCompare = MaxIdRsToCompare
    '
    Set @sql = replace(@sql, '#colList#', @colList)
    Print @Sql
    Exec (@sql)

    Exec f$.DropObj 'f$.tmp#spid#', @silent=1

f$.ScriptCompareRowsTemplate*/

With 
  Prm as (select @TQryTag as TQryTag, @RQryTag as RQryTag)
  --Prm as (select 'T' as TQryTag, 'R' as RQryTag)
, AllElementsToBuildQry as
  (
  Select 
    Prm.*
  , T.BatchComment as TQry
  , R.BatchComment as RQry
  , Convert(Nvarchar(max), Serverproperty('servername')) as servername
  , Coalesce(InThisFunction.CommentContent, TestingMode.batchComment) as QryTemplate
  From 
    Prm 
    CROSS APPLY f$.GetCommentFromBatch('CodeIsSelectedForRun') as RunContext
    CROSS APPLY f$.GetCommentFromBatch(Case When RunContext.BatchComment <> '_True_' Then Prm.TQryTag Else 'T' End) T  
    CROSS APPLY f$.GetCommentFromBatch(Case When RunContext.BatchComment <> '_True_' Then Prm.RQryTag Else 'R' End) R
    -- Normal operation when calling this function
    Outer Apply 
    (
    Select * 
    From f$.GetDelimitedCommentFromText
         (
           object_definition(Object_id('f$.ScriptCompareRows'))
         , 'f$.ScriptCompareRowsTemplate'
         , ' in f$.ScriptCompareRows'
         ) 
    Where RunContext.BatchComment <> '_True_'
    ) as InThisFunction
    -- for testing pourpose when testing this code by selecting inside the function source and running
    Outer Apply 
    (
    Select * 
    From f$.GetCommentFromBatch('f$.ScriptCompareRowsTemplate') T 
    Where RunContext.BatchComment = '_True_'
    ) as TestingMode
  )
Select 
  r5.s as Sql, 1 as Seq
From 
  AllElementsToBuildQry
  CROSS APPLY f$.iReplace (QryTemplate, '#Spid#', convert(nvarchar, @@spid)) as r0
  CROSS APPLY f$.iReplace (r0.s, '#TQry#', TQry) as r1
  CROSS APPLY f$.iReplace (r1.s, '#RQry#', RQry) as r2
  CROSS APPLY f$.iReplace (r2.s, '#serverName#', Servername) as r3
  CROSS APPLY f$.iReplace (r3.s, '#TQryTag#', TQryTag) as r4
  CROSS APPLY f$.iReplace (r4.s, '#RQryTag#', RQryTag) as r5
)
/*  -- this comment is for testing the function call from the outside, select only code in this comment to test
/*CodeIsSelectedForRun1_True_CodeIsSelectedForRun*/
/*T2 select * From sys.tables T2*/
/*R2 select * From sys.tables where name not like '%test%' R2*/
Insert into f$.QueryToRun (Sql, seq) Select * From f$.ScriptCompareRows ('T2', 'R2')
Exec f$.RunQuery
*/
GO
Exec f$.dropObj 'f$.SqlBatchView'
GO
--f$SignatureForCleanup
Create View f$.SqlBatchView
as
  Select qt.text as batch
  From 
    sys.dm_exec_requests er
    Cross Apply 
    sys.dm_exec_sql_text(er.sql_handle) as qt
  Where er.session_id = @@SPID
GO
-------------------------------------------------------------------------------------------------------------
-- This procedure is to make sure that all code objects can be compiled and remove those who can't be
-------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.assertDbCode'
GO
--f$SignatureForCleanup
CREATE PROC f$.assertDbCode @TargetDb sysname, @SilentMode Int = 0, @IncObjLike nvarchar(max) = '%', @ExcObjLike nvarchar(max) = ''
as
Begin
  Set Nocount On

  --Comparison table is created--
  DECLARE @NbOfObjects int = 0;

  Exec f$.DropTempTb '#SnapshotObjs'   --drop table #SnapshotObjs
  Create Table #SnapshotObjs
  (
    targetDb sysname
  , fullTgtDbObjName sysname
  , fullObjName sysname
  , Typename sysname
  , def nvarchar(max)
  , ExecIsQuotedIdentOn nvarchar(3)
  , ExecIsAnsiNullsOn nvarchar(3)
  )
   
  /*---GetObjDef---
  -- positioning in the desired database and copying the objects' list in a temporary table that is already created
  Use [#TargetDb#]
  ;With 
    AllObjects as
    (
    SELECT 
      convert(sysname, '#targetDb#') as targetDb
    , QuoteName('#targetDb#')+'.'+QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name) as fullTgtDbObjName
    , QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name) as fullobjname
    , Case 
        When Obj.type IN ('P') THEN 'Procedure'
        When Obj.type IN ('FN', 'TF', 'IF') THEN 'Function'
        When Obj.type IN ('TR') THEN 'Trigger' 
        When Obj.type IN ('V') THEN 'View' 
        ELSE 'INCONNU'
      END as TypeName
    , OBJECT_DEFINITION(Object_id) as def 
    , Case When objectproperty(Object_id, 'ExecIsQuotedIdentOn')=1 Then 'ON' Else 'OFF' End as ExecIsQuotedIdentOn
    , Case When objectproperty(Object_id, 'ExecIsAnsiNullsOn')=1 Then 'ON' Else 'OFF' End as ExecIsAnsiNullsOn
    FROM sys.objects as Obj
    Where type IN ('P','FN','TF','IF','TR','V') 
      And Not Exists
          (
          Select * 
          from sys.dm_sql_referencing_entities(QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name), 'OBJECT') as ref
          Where OBJECTPROPERTY(ref.referencing_id, 'IsUserTable') = 1
          )
    )
  Insert into #SnapshotObjs
  Select AllObjects.*
  From  
    AllObjects
    Cross Apply f$.MatchByLikeListAndReduceByNotLikeList (FullObjName, '#IncObjLike#', '#ExcObjLike#') as UseFilteringEffectOfCrossApply

  ---GetObjDef---*/
  Insert Into f$.ScriptToRun(sql, seq)
  Select r2.s, 1
  from 
    f$.GetCommentFromSqlObj(@@PROCID, '---GetObjDef---') as B
    Cross Apply f$.iReplace(B.CommentContent, '#TargetDb#', @TargetDb) as r0
    Cross Apply f$.iReplace(r0.s, '#IncObjLike#', @IncObjLike) as r1
    Cross Apply f$.iReplace(r1.s, '#ExcObjLike#', @ExcObjLike) as r2
  Exec f$.RunScript @printOnly=0, @Silent=@SilentMode -- execute initialization of the #SnapShotDb table
  
  DECLARE @CurrentNbOfObjects int = 0;
  SELECT @NbOfObjects = COUNT(*) FROM #SnapshotObjs 
  
  -- Unless lucky, objects can't be created all at once because we don't guess dependency order
  -- so we repeat drop/create object until the number of objects created become equals
  -- which means no more objects are created in the iteration
  -- We try to reduce attempts by using info stored in Sql_dependencies
  While (@NbOfObjects <> @CurrentNbOfObjects)
  Begin
    SELECT @NbOfObjects = COUNT(*)   
    FROM #SnapshotObjs 
    Where OBJECT_ID(fullTgtDbObjName) IS NOT NULL -- if the object was created, that means its Object_id is still there
   ;WITH 
      TODO AS 
      (
      SELECT 
        /*---Drop and recreate---

        Use #TargetDb#

        Set quoted_identifier #ExecIsQuotedIdentOn#
        Set Ansi_Nulls #ExecIsAnsiNullsOn#
        Begin Try
          If Object_id('#fullObjName#') IS NOT NULL Drop #TypeName# #FullObjName#
  
          Declare @createObj nvarchar(max)
          Select @createObj = Def From #SnapshotObjs Where fullObjName = '#fullObjName#'
          Exec sp_executeSql @CreateObj
        End Try
        Begin Catch
          Print 'Cannot drop/recreate #FullObjName# : '+Str(error_number())+ ' ' +error_message()
        End Catch
  
        ---Drop and recreate---*/
        B.CommentContent as DropEtRecreate
      , fullObjname
      , typeName
      , TargetDb
      , ExecIsAnsiNullsOn
      , ExecIsQuotedIdentOn
      , Def
      -- A trigger must not be created before the object on which it is dependant. Here, the only case is the view
      -- If the view is deleted, the trigger will disappear if he was created before the view was.
      , Row_Number() Over (Order by charindex(typeName, 'Function, View, Trigger, Procedure'), fullobjname) as Seq 
      FROM 
        #SnapshotObjs 
        Cross Apply f$.GetCommentFromSqlObj(@@PROCID, '---Drop and recreate---') as B
      Where OBJECT_ID(fullTgtDbObjName) IS NOT NULL -- if object exists attempt to recreate it to see if it is valid
      )
    Insert into f$.ScriptToRun (sql, seq)
    SELECT 
      SqlPrep.finalReplace, seq
    FROM 
      TODO 
      Cross Apply f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(ToDo.DropEtRecreate, (Select Todo.* For XML RAW, TYPE)) as SqlPrep
    Order by Seq
    --Script execution--
    Exec f$.RunScript @printOnly=0, @Silent=@SilentMode 
  
    --Verifying how many objects were recreated--
    SELECT @CurrentNbOfObjects = COUNT(*)   
    FROM #SnapshotObjs 
    Where OBJECT_ID(fullTgtDbObjName) IS NOT NULL -- if the object was created, that means its Object_id is still there
  
  END -- While

  If exists(Select * FROM #SnapshotObjs Where OBJECT_ID(fullTgtDbObjName) IS NULL) -- some objects weren't recreated
  Begin
    --so display them
    Insert into f$.ScriptToRun (sql, seq)
    SELECT r0.s, ROW_NUMBER() Over (Order by fullTgtDbObjName) as Seq
    FROM 
      #SnapshotObjs 
      cross apply f$.iQReplace('Print "f$.AssertDbCode assertion failed : Object #fullTgtDbObjName# couldn""t be created"', '#fullTgtDbObjName#', fullTgtDbObjName) as r0
    Where OBJECT_ID(fullTgtDbObjName) IS NULL -- the objects that weren't recreated
    Exec f$.RunScript @PrintOnly=0, @Silent=@SilentMode

    Return (1) -- non zéro RC
  End
  Else
    Return (0)
End
GO
-----------------------------------------------------------------------------------------
-- This procedure transfers all the coded objects from a source database to a target one
-----------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.transferDbObj'
GO
--f$SignatureForCleanup
CREATE PROC f$.transferDbObj @SourceDb sysname, @TargetDb sysname, @CreateOnly int = 0, @SilentMode Int = 0, @IncObjLike nvarchar(max) = '%', @ExcObjLike nvarchar(max) = ''
as
Begin
    Set Nocount On

  --drop table #SnapshotObjs
  Exec f$.DropTempTb '#SnapshotSrcObjs'
  Create Table #SnapshotSrcObjs
  (
    SourceDb sysname
  , TargetDb sysname
  , schemaName sysname
  , fullSrcDbObjName sysname
  , fullTgtDbObjName sysname
  , fullObjName sysname
  , Typename sysname
  , def nvarchar(max)
  , ExecIsQuotedIdentOn nvarchar(3)
  , ExecIsAnsiNullsOn nvarchar(3)
  )

  Exec f$.DropTempTb '#SnapshotSrcObjsDependencies'
  Create Table #SnapshotSrcObjsDependencies
  (
    fullObjName    sysname 
  , fullObjTgtNameRef sysname NULL
  )
  Create Index iSnapshotSrcObjsDependencies On #SnapshotSrcObjsDependencies(fullObjName, fullObjTgtNameRef)
   
  /*---GetObjDefSource---
  -- Get a table containing all the pertinent information for the objects in the source databse
  Use [#SourceDb#]
  ;With 
    AllObjects As
    (
    SELECT 
      convert(sysname, '#SourceDb#') as SourceDb
    , convert(sysname, '#TargetDb#') as TargetDb
    , Object_schema_name(Object_id) as SchemaName
    , QuoteName('#SourceDb#')+'.'+QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name) as fullSrcDbObjName
    , QuoteName('#TargetDb#')+'.'+QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name) as fullTgtDbObjName
    , QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name) as fullobjname
    , Case 
        When Obj.type IN ('P') THEN 'Procedure'
        When Obj.type IN ('FN', 'TF', 'IF') THEN 'Function'
        When Obj.type IN ('TR') THEN 'Trigger' 
        When Obj.type IN ('V') THEN 'View' 
        ELSE 'INCONNU'
      END as TypeName
    , OBJECT_DEFINITION(Object_id) as def 
    , Case When objectproperty(Object_id, 'ExecIsQuotedIdentOn')=1 Then 'ON' Else 'OFF' End as ExecIsQuotedIdentOn
    , Case When objectproperty(Object_id, 'ExecIsAnsiNullsOn')=1 Then 'ON' Else 'OFF' End as ExecIsAnsiNullsOn
    FROM 
      sys.objects as Obj
    Where type IN ('P','FN','TF','IF','TR','V') 
      And Not Exists
       (
       Select * -- we don't attempt to handle function referenced by table default constraints
       from sys.dm_sql_referencing_entities(QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name), 'OBJECT') as ref
       Where OBJECTPROPERTY(ref.referencing_id, 'IsUserTable') = 1
       )
    )
  Insert into #SnapshotSrcObjs
  Select AllObjects.*
  From  
    AllObjects
    Cross Apply f$.MatchByLikeListAndReduceByNotLikeList (FullObjName, '#IncObjLike#', '#ExcObjLike#') as UseFilteringEffectOfCrossApply

  Insert Into #SnapshotSrcObjsDependencies (fullObjName, fullObjTgtNameRef)
  Select Distinct 
    Obj.FullObjName
  , QuoteName('#TargetDb#')+'.'+QuoteName(Object_schema_name(referenced_major_id))+'.'+QuoteName(Object_name(referenced_major_id))
  From 
    #SnapshotSrcObjs as Obj
    LEFT JOIN
    sys.Sql_Dependencies Sd
    ON Sd.Object_id = Object_id (fullSrcDbObjName)
  ---GetObjDefSource---*/
  Insert Into f$.ScriptToRun(sql, seq)
  Select r3.s, 1
  from 
    f$.GetCommentFromSqlObj(@@PROCID, '---GetObjDefSource---') as B
    Cross Apply f$.iReplace(B.CommentContent, '#SourceDb#', @SourceDb) as r0
    Cross Apply f$.iReplace(r0.s, '#TargetDb#', @TargetDb) as r1
    Cross Apply f$.iReplace(r1.s, '#IncObjLike#', @IncObjLike) as r2
    Cross Apply f$.iReplace(r2.s, '#ExcObjLike#', @ExcObjLike) as r3
  Exec f$.RunScript @printOnly=0, @Silent=@SilentMode -- execute initialisation of the #SnapShotDbSource table

  --We also need the object information from the target database: Since the goal is to make sure both database have the same coded objects,
  --we must delete those that were there in the target database prior to the execution of the precedure before creating the new ones from the source
  Exec f$.DropTempTb '#SnapshotTgtObjs'
  Create Table #SnapshotTgtObjs
  (
    TargetDB sysname
  , fullTgtDbObjName sysname 
  , fullObjName sysname
  , Typename sysname
  )
   
  /*---GetObjDefTarget---
  -- Get a table containing all the pertinent information for the objects in the target databse
  Use [#TargetDB#]
  ;With 
    AllObjects As
    (
    SELECT 
      convert(sysname, '#TargetDB#') as TargetDB
    , QuoteName('#TargetDB#')+'.'+QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name) as fullTgtDbObjName
    , QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name) as fullobjname
    , Case 
        When Obj.type IN ('P') THEN 'Procedure'
        When Obj.type IN ('FN', 'TF', 'IF') THEN 'Function'
        When Obj.type IN ('TR') THEN 'Trigger' 
        When Obj.type IN ('V') THEN 'View' 
        ELSE 'INCONNU'
      END as TypeName
    FROM sys.objects as Obj
    Where type IN ('P','FN','TF','IF','TR','V') 
      And Not Exists
       (
       Select * 
       from sys.dm_sql_referencing_entities(QuoteName(Object_schema_name(Object_id))+'.'+QuoteName(name), 'OBJECT') as ref
       Where OBJECTPROPERTY(ref.referencing_id, 'IsUserTable') = 1
       )
    )
  Insert into #SnapshotTgtObjs
  Select AllObjects.*
  From 
    AllObjects
    Cross Apply [#CallingDb#].f$.MatchByLikeListAndReduceByNotLikeList (FullObjName, '#IncObjLike#', '#ExcObjLike#') as UseFilteringEffectOfCrossApply
  ---GetObjDefTarget---*/
  Insert Into f$.ScriptToRun(sql, seq)
  Select r3.s, 1
  from 
    f$.GetCommentFromSqlObj(@@PROCID, '---GetObjDefTarget---') as B
    Cross Apply f$.iReplace(B.CommentContent, '#TargetDB#', @TargetDB) as r0
    Cross Apply f$.iReplace(r0.s, '#IncObjLike#', @IncObjLike) as r1
    Cross Apply f$.iReplace(r1.s, '#ExcObjLike#', @ExcObjLike) as r2
    Cross Apply f$.iReplace(r2.s, '#CallingDb#', db_Name()) as r3
  Exec f$.RunScript @printOnly=0, @Silent=@SilentMode -- execute initialisation of the #SnapShotDbTarget table

  --We then proceed to drop the objects in the target database thanks to the information from the table SnapshotDbTarget 
  --Option @CreateOnly must be = 0 otherwise this query won't generated code (see where clause)
  ;WITH 
   TODO AS 
   (
   SELECT 
     /*---DropTargetDB---
     Use #TargetDb#
     Begin Try
       If Object_id('#fullObjName#') IS NOT NULL Drop #TypeName# #FullObjName#
     End Try
     Begin Catch
       If #SilentMode#=0
         Print 'Error when dropping #FullObjName# : '+Str(error_number())+ ' ' +error_message()
     End Catch
    ---DropTargetDB---*/
     B.CommentContent as DropTargetDB
   , fullObjname
   , typeName
   , TargetDb
   , Str(@SilentMode) as SilentMode
   , Row_Number() Over (Order by charindex(typeName, 'Function, View, Trigger, Procedure'), fullobjname) as Seq 
    FROM 
     f$.GetCommentFromSqlObj(@@PROCID, '---DropTargetDB---') as B
     Cross join #SnapshotTgtObjs
   Where OBJECT_ID(fullTgtDbObjName) IS NOT NULL -- If the object was created because its object_id exists
   )
  Insert into f$.ScriptToRun (sql, seq)
  SELECT r3.s, seq
  FROM 
    TODO 
    Cross Apply f$.iReplace(DropTargetDB, '#TargetDb#', TargetDb) as r0
    Cross Apply f$.iReplace(r0.s, '#TypeName#', Typename) as r1
    Cross Apply f$.iReplace(r1.s, '#fullObjName#', fullObjName) as r2
    Cross Apply f$.iReplace(r2.s, '#SilentMode#', SilentMode) as r3
  WHERE @CreateOnly = 0  -- If @createOnly = 1, no rows are selected, so no drops are generated
  Order by Seq
  --Script Execution--
  Exec f$.RunScript @printOnly=0, @Silent=@SilentMode
 
  --We start the object creation loop: we loop until the number of objects in the database is equal to the number of objects in the last iteration

  --Creating the comparison table--
  DECLARE @NbOfObjects int = 0;
  DECLARE @CurrentNbOfObjects int = 1;

  -- recreate schema
  ;WITH 
    DistinctSchemas as (Select Distinct TargetDb, SchemaName from  #SnapshotSrcObjs)
  , TODO AS 
    (
    SELECT DISTINCT 
      /*---RecreateSchema---
      Use #TargetDB#
      If Schema_Id('#SchemaName#') IS NULL Exec ('Create Schema #SchemaName# Authorization dbo')
      ---RecreateSchema---*/
      B.CommentContent as Recreate
    , schemaName
    , TargetDb
    , Row_number() Over (Order by SchemaName) as Seq 
    FROM 
      f$.GetCommentFromSqlObj(@@PROCID, '---RecreateSchema---') as B
      Cross join DistinctSchemas as S
      Where SCHEMA_ID(S.SchemaName) IS NULL -- creer seulement schema pas déjà créés
    )
  Insert into f$.ScriptToRun (sql, seq)
  SELECT r1.s, seq
  FROM 
    TODO 
    Cross Apply f$.iReplace(ToDo.Recreate, '#SchemaName#', TODO.SchemaName) as r0
    Cross Apply f$.iReplace(r0.s, '#targetDb#', TODO.TargetDb) as r1
  Order by Seq
  --Script Execution--
  Exec f$.RunScript @printOnly=0, @Silent=@SilentMode
 
  -- Unless lucky, objects can't be created all at once because we don't guess dependency order
  -- so we repeat drop/create object until the number of objects created become equals
  -- which means no more objects are created in the iteration
  Declare @nbOfPasses as Int = 0
  While (@CurrentNbOfObjects > @NbOfObjects) 
  Begin
    Set @nbOfPasses = @nbOfPasses + 1
    Select @NbOfObjects = count(*)
    From #SnapshotSrcObjs
    Where OBJECT_ID(fullTgtDbObjName) IS NOT NULL

    ;WITH 
      TODO AS 
      (
      SELECT 
        /*---Recreate---
        --- Pass #NbOfPasses# -----
        Use #TargetDB#
        Set quoted_identifier #ExecIsQuotedIdentOn#
        Set Ansi_Nulls #ExecIsAnsiNullsOn#

        Begin Try
          Declare @createObj nvarchar(max)
          Select @createObj = Def From #SnapshotSrcObjs Where fullObjName = '#fullObjName#'
          Exec sp_executeSql @CreateObj
        End Try
        Begin Catch
          If #SilentMode#=0
             Print 'Error when creating #FullObjName# : '+Str(error_number())+ ' ' +error_message()
        End Catch
        ---Recreate---*/
        B.CommentContent as Recreate
      , fullObjname
      , fullTgtDbObjName
      , typeName
      , SourceDb
      , TargetDB 
      , ExecIsAnsiNullsOn
      , ExecIsQuotedIdentOn
      , def
      , Str(@SilentMode) as SilentMode
      , @nbOfPasses as NbOfPasses
      --Since they're usually the most dependants, we make sure to create the triggers last, to reduce the number of loops needed to achieve the entire creation.
      , Row_Number() Over (Order by charindex(typeName, 'Function, View, Procedure, Trigger'), fullobjname) as Seq 
      FROM 
        f$.GetCommentFromSqlObj(@@PROCID, '---Recreate---') as B
        Cross join #SnapshotSrcObjs as S
        Where OBJECT_ID(S.fullTgtDbObjName) IS NULL -- creer seulement objet pas déjà créés
          AND Not Exists
              (
              select *
              From #SnapshotSrcObjsDependencies as Dep
              Where Dep.fullObjName = S.fullObjName 
                And Dep.fullObjTgtNameRef IS NOT NULL
                And Object_id(Dep.fullObjTgtNameRef) IS NULL
              )
      )
    Insert into f$.ScriptToRun (sql, seq)
    SELECT r4.s, seq
    FROM 
      TODO 
      Cross Apply f$.iReplace(Recreate, '#TargetDb#', TargetDb) as r0
      Cross Apply f$.iReplace(r0.s, '#ExecIsAnsiNullsOn#', ExecIsAnsiNullsOn) as r1
      Cross Apply f$.iReplace(r1.s, '#ExecIsQuotedIdentOn#', ExecIsQuotedIdentOn) as r2
      Cross Apply f$.iReplace(r2.s, '#fullObjName#', fullObjName) as r3
      Cross Apply f$.iReplace(r3.s, '#SilentMode#', SilentMode) as r4
    Order by Seq
    --Script Execution--
    Exec f$.RunScript @printOnly=0, @Silent=@SilentMode

    --We record how many objects have been created for our loop criteria--
    Select @CurrentNbOfObjects = count(*)
    From #SnapshotSrcObjs
    Where OBJECT_ID(fullTgtDbObjName) IS NOT NULL
    
  END -- While

  --Verification that sends a result sets of the objects that were not created in the target database, if any.
  If Exists (Select * From #SnapshotSrcObjs Where OBJECT_ID(fullTgtDbObjName) IS NOT NULL)
  Begin
    Insert into f$.ScriptToRun (sql, seq)
    SELECT r0.s, ROW_NUMBER() Over (Order by fullTgtDbObjName) as Seq
    FROM 
      #SnapshotSrcObjs
      cross apply f$.iQReplace('Print "f$.transferDbObj assertion failed : Object #fullTgtDbObjName# couldn""t be created"', '#fullTgtDbObjName#', fullTgtDbObjName) as r0
    Where OBJECT_ID(fullTgtDbObjName) IS NULL -- the objects that weren't recreated
    Exec f$.RunScript @PrintOnly=0, @Silent=@SilentMode

    Return (1)
  End
  Else
  Begin
    Exec f$.assertDbCode @targetDb, @SilentMode=1  -- recreate everything once to have clean dependencies in sys.sql_dependencies
    Return (0)
  End
End
GO
If object_id('f$.CleanupSchemaf$OnOtherDb') is not null 
  drop Procedure f$.CleanupSchemaf$OnOtherDb
GO
--f$SignatureForCleanup
Create Procedure f$.CleanupSchemaf$OnOtherDb @remoteDb sysname
as
Begin
  Declare @CleanupSchemaProc nvarchar(max) = OBJECT_DEFINITION(Object_id('f$.CleanupSchema'))
  Declare @dropRemoteExec nvarchar(max) = 'Use '+@remoteDb+'; if Object_id(''f$.CleanupSchema'') Is not null drop procedure f$.CleanupSchema'
  Exec (@dropRemoteExec);

  Declare @schemaId int
  Declare @remoteExec nvarchar(max) = 'Use '+@remoteDb+'; Select @schemaId = Schema_id(''f$'')'
  Exec sp_executeSql @RemoteExec, N'@schemaId Int Output', @schemaId Output
  If @SchemaId IS NULL Return

  Set @remoteExec = 'Use '+@remoteDb+'; Exec (@CleanupSchemaProc)'
  Exec sp_executeSql @RemoteExec, N'@CleanupSchemaProc nvarchar(max)', @CleanupSchemaProc 
  Set @remoteExec = 'Use '+@remoteDb+'; Exec f$.CleanupSchema f$'
  Exec sp_executeSql @RemoteExec
End
GO
-- ****************************************************************************************
-- Duplicate this schema object to other databases to have same fonctions across them
-- ****************************************************************************************
Exec f$.DropObj 'f$.AutoDuplicateToolsToDb'
GO
--f$SignatureForCleanup
Create Proc f$.AutoDuplicateToolsToDb @LstDb NVarchar(max) = '', @Silent Int = 1
as
Begin
  Set Nocount On

  If len(@lstDb) = 0
  Begin
    Print 'Supply a non-empty database list through ­@LstDb parameter'
    Return
  End

  If Len(@lstDb) > 0 -- arrive quand aucune Bd est là
    Print 'Replicating objects to '+@LstDb

  Set nocount on
  /*ForEachDbReplaceAndRunCleanupProcedures

    /*---RunRemoteCleanupAndRestartSchema--- -- remove any trace of previous library if already installed there
    If Object_id('f$.CleanupLibraryObjects') IS NOT NULL
      Exec f$.CleanupLibraryObjects @Silent=#Silent#

    -- Create other schema if missing
    If Schema_id('f$') IS NULL EXEC('Create Schema f$ Authorization Dbo')

    If Object_Id('f$.RealScriptToRun') IS NOT NULL Drop Table f$.RealScriptToRun

    ---RunRemoteCleanupAndRestartSchema---*/

    Insert into f$.ScriptToRun(Sql, seq)
    Select B.batchComment, 1 
    From f$.GetCommentFromBatch ('---RunRemoteCleanupAndRestartSchema---') as B

    -- recreate table f$.RealScriptToRun at target Db #DestDb#

    Insert into f$.AppendToScriptToRun(Sql, seq)
    Select CreateTableWithColsWithoutConstraintName, 1
    From f$.TableInfo('f$.RealScriptToRun')

    -- recreate table f$.RealScriptToRun at target Db #DestDb#
    Insert into f$.AppendToScriptToRun(Sql, seq)
    Select CreateIndex, 1
    From f$.IndexInfo('f$.RealScriptToRun',NULL)
    
    Insert into f$.AppendToScriptToRun(Sql, seq)
    Select Object_definition(Object_id(Objs.Objname)), Seq
    From (Values (1, 'f$.ObjectInfo'), (2, 'f$.GenDropObj'), (3, 'f$.DropObj'), (4, 'f$.CleanupLibraryObjects')) as Objs(Seq, ObjName)

    Exec f$.RunScript @PrintOnly=0, @Silent=#Silent#, @RunOnThisDb = '#DestDb#'

    --Declare @DbSrc sysname = Db_name()
    --Exec f$.transferDbObj @SourceDb=@dbSrc, @TargetDb='#DestDb#', @CreateOnly=1, @SilentMode='#Silent#'

    ForEachDbReplaceAndRunCleanupProcedures*/
  Insert into f$.ScriptToRun (sql, seq)
  Select R1.s, D.Seq
  From 
    f$.SplitList(',', @LstDb) D -- obtient la liste des DB
    CROSS APPLY f$.GetCommentFromBatch ('ForEachDbReplaceAndRunCleanupProcedures') as Cmt
    Cross Apply f$.iReplace(Cmt.BatchComment, '#DestDb#', D.Item) as R0 
    Cross Apply f$.iReplace(r0.s, '#Silent#', convert(nvarchar,@Silent)) as R1
  Where D.Item <> DB_Name() -- on réplique vers les autres DB, on touche pas au code local
    And Db_Id(D.Item) IS NOT NULL -- il faut que la Bd dans la liste existe (on tolère ce petit laximsme de configuration)
  Exec f$.RunScript @Silent=@Silent

    -- store other code objects to replicate
  select 
    Obj.type_desc
  , f$.UnquoteName(f$.FullObjName(Object_id)) as Obj
  , Case When R.referencing_id IS NOT NULL Then f$.UnquoteName(f$.FullObjName(R.referencing_id)) Else NULL End as RefBy
  into #Ref
  from 
    sys.objects Obj
    outer apply sys.dm_sql_referencing_entities (Object_Schema_Name(Obj.Object_id) + '.' + name, 'OBJECT') R
  Where 
      Object_Schema_Name(Obj.Object_id) = 'f$'
  And type IN ('P', 'TF', 'IF', 'FN', 'V', 'U', 'TR') 

  --select * from #ref order by obj

  -- find correct creation order for code objects
  ;With 
    UnReferencedObj as
    (
    select type_desc, Obj, RefBy, convert(nvarchar(max), Obj) as Arbre, 9999 as dependencyDepth
    from #ref
    Where RefBy IS NULL
    )
  , ReferencedObj as
    (
    select type_desc, Obj, RefBy, convert(nvarchar(max), Obj) + '/'  as Arbre, 1 as dependencyDepth
    from #ref
    Where RefBy IS NOT NULL
    )
  , trackAncestors as
    (
    select type_desc, Obj, RefBy, convert(nvarchar(max), Obj) as Arbre, 1 as dependencyDepth
    from ReferencedObj
    UNION ALL
    select R.type_desc, R.Obj, R.RefBy, T.Arbre + '/' + R.Obj, dependencyDepth + 1 
    from 
      trackAncestors T 
      Join 
      #ref R On R.Obj = T.Refby
    )
  , ObjectTree as 
    (
    Select * From UnReferencedObj
    Union all
    Select * from trackAncestors 
    )
  , MaxAncestorsbyObj as
    (
    Select type_desc, obj, arbre, dependencyDepth, Max(dependencyDepth) Over (Partition by obj) as MaxDependencyFound
    From ObjectTree 
    )
  select distinct type_desc, obj, MaxDependencyFound 
  Into #TransferOrder
  From MaxAncestorsbyObj
  where dependencyDepth = MaxDependencyFound
    And type_desc <> 'User_table'
  Order by MaxDependencyFound, obj asc
  --Select * from #TransferOrder

  -- replicate code objects to other databases
  /*ForEachDbRunCreateObj

  Declare @SqlForOtherDb nvarchar(Max); 
  Declare @SqlMain nvarchar(Max); 

  Set @SqlForOtherDb = Object_Definition (Object_id('#ObjName#'))
  Set @SqlMain = 'Use [#DestDb#]; Exec sp_executeSql @SqlForOtherDb' 
  Exec sp_ExecuteSql @SqlMain, N'@SqlForOtherDb nvarchar(Max)', @SqlForOtherDb

  ForEachDbRunCreateObj*/
  Insert into f$.ScriptToRun (sql, seq)
  Select R1.s, Row_number() Over (Order by MaxDependencyFound, obj) as Seq
  From 
    f$.GetCommentFromBatch ('ForEachDbRunCreateObj') as Cmt

    Join f$.SplitList(',', @LstDb) D -- obtient la liste des DB
    ON D.Item <> DB_Name() -- on réplique vers les autres DB, on touche pas au code local
    And Db_Id(D.Item) IS NOT NULL -- il faut que la Bd dans la liste existe (on tolère ce petit laximsme de configuration)

    join #TransferOrder Ord ON Ord.Obj Not In ('f$.ObjectInfo', 'f$.GenDropObj', 'f$.DropObj', 'f$.CleanupLibraryObjects')
  
    Cross Apply f$.iQReplace(Cmt.BatchComment, '#DestDb#', D.Item) as R0 
    Cross Apply f$.iQReplace(R0.s, '#ObjName#', Ord.Obj) as R1

  Exec f$.RunScript @Silent=@Silent 

End -- f$.AutoDuplicateToolsToDb
GO
--------------------------------------------------------------------------------------
-- This proc empty a database of all its data by default, or select list of tables
-- to be emptied on a multi like and multi not like criterias,
-- but preserves index and foreign keys
--------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.FlushDataFromDb'
GO
--f$SignatureForCleanup
Create Proc f$.FlushDataFromDb @db sysname, @TablesLikes nvarchar(max) = N'%', @TablesNotLikes nvarchar(max) = ''
as
Begin
  Set nocount on
  Exec f$.AutoDuplicateToolsToDb @LstDb=@Db, @Silent=1
  --declare @db sysname = 'PAIE_REF'
  Declare @DbFiles table (name sysname, physical_name nvarchar(512), type_desc  sysname, file_Id Int) 
  Insert into @DbFiles
  Exec ('Use '+@Db+'; Select name, physical_name, type_desc, file_id from sys.database_files')
--  select * from @dbfiles
  ;With
    SqlTemplate as
    (
    Select
      @TablesLikes as TablesLikes
    , @TablesNotLikes as TablesNotLikes
    , '
    Use #Db#
    Alter database #Db# set recovery simple
    declare @Fk table (fullTbName sysname, AddForeignKey nvarchar(max), DropForeignKey nvarchar(max))
    Insert into @Fk Select F.fullTbName, F.AddForeignKey, F.DropForeignKey From f$.ForeignKeyInfo(NULL) F

    insert into f$.ScriptToRun (sql, seq)
    Select "Use #Db#; "+ DropForeignKey, ROW_NUMBER() Over (Order by FullTbName)
    From @FK
    Exec f$.RunScript @printOnly=0

    ;With 
      tb as 
      (
      Select f$.FullObjName(Object_id) as fullTbName, "Use #Db#; truncate table #FullTbName#" as Template
      From Sys.tables
      )
    insert into f$.AppendToScriptToRun  (sql, seq)
    Select r0.s, ROW_NUMBER() Over (Order by fullTbName) as Seq
    From 
      Tb
      cross apply f$.MatchByLikeListAndReduceByNotLikeList(Tb.fullTbName, "#TablesLikes#", "#TablesNotLikes#")
      cross apply f$.iQReplace(Template, "#FullTbName#", Tb.fullTbName) as r0
    Where fullTbName <> "[f$].[RealScriptToRun]"

    insert into f$.AppendToScriptToRun  (sql, seq)
    Select "Use #Db#; "+ AddForeignKey, ROW_NUMBER() Over (Order by FullTbName)
    From @FK

    Exec f$.RunScript @printOnly=0
    ' as Sql
  )
  Insert into f$.ScriptToRun (sql, seq)
  Select 
     r2.s, 1
  From
    SqlTemplate 
    CROSS APPLY f$.iReplace(SqlTemplate.Sql, '#Db#', @Db) as r0
    CROSS APPLY f$.iReplace(r0.s, '#TablesLikes#', TablesLikes) as r1
    CROSS APPLY f$.iQReplace(r1.s, '#TablesNotLikes#', TablesNotLikes) as r2
  Exec f$.RunScript @printOnly=0

  ;With 
    SqlTemplate as
    (
    Select
      f$.AdjConcatRS 
      (  ', '
       , (
         Select f$.CMax(r1.s) as [text()]
         From 
           (select * from @DbFiles Where type_desc <> 'LOG') F
           CROSS APPLY f$.iReplace(', (name="#name#", filename="#physical_name#.Snap")', '#name#', F.name) as r0
           CROSS APPLY f$.iQReplace(r0.s, '#physical_name#', F.physical_name) as r1
         Order BY F.name
         For XML PATH('')
         )
      ) as FileSpecs
    , '
      -- powerful "bugfeature" to reduce virtual log file, and then 
      -- allow to reduce the log to the max  (a log must keep at least 2 virtual log file)

      If Db_id("#Db#_SnapshotTmp") IS NOT NULL Exec ("Drop Database #Db#_SnapshotTmp")

      Create Database [#db#_SnapshotTmp]
      ON 
      #FileSpecs#
      as snapshot of [#db#]

      Alter Database [#db#] Set offline with rollback immediate
      Alter Database [#db#] Set Online
      Restore Database [#db#] From DATABASE_SNAPSHOT = "#db#_SnapshotTmp"
      Drop database [#db#_SnapshotTmp]
    ' as Sql
    )
  , ServerEdition as (Select convert(sysname, SERVERPROPERTY('Edition')) as Edition)
  , ServerEditionEnabledForSnapshot (hehe) as 
    (
    Select top 1 1 as Hehe
    From 
      ServerEdition 
      JOIN 
      (Values ('Entreprise%'), ('Developer%') ) As ServerEditionLikes(likes)
      ON ServerEdition.Edition Like ServerEditionLikes.Likes 
    )
  Insert into f$.ScriptToRun (sql, seq)
  Select 
     r1.s, 1
  From
    ServerEditionEnabledForSnapshot -- if it returns no row, it stops all process
    CROSS JOIN SqlTemplate 
    CROSS APPLY f$.iQReplace(SqlTemplate.Sql, '#Db#', @Db) as r0
    CROSS APPLY f$.iQReplace(r0.s, '#FileSpecs#', SqlTemplate.FileSpecs) as r1
  Exec f$.RunScript @printOnly=0

  -- Attempt to reduce all files including log, in case this procedure is ran on 
  -- an edition not able to use snapshot, which will prevent the previous code from running log reduction
  /*---ReduceFileSize---
  Use #Db#
  DBCC SHRINKFILE (#name#, 5)
  ---ReduceFileSize---*/
  ;With SelectedFiles (file_Id, xFiles) as (Select file_Id, (select @db as Db, D.name For Xml raw, type) From @DbFiles D)
  Insert into f$.ScriptToRun (sql, seq)
  Select 
     r.finalReplace, ROW_NUMBER() Over (order by FILE_ID) as seq
  From
    SelectedFiles as S
    Cross apply f$.GetCommentFromSqlObj(@@ProcId, '---ReduceFileSize---') as B
    CROSS APPLY f$.ReplaceTagsMatchingXMLAttributesNamesByTheirValue(B.CommentContent, S.xFiles) as r
  Exec f$.RunScript @PrintOnly=0

  Exec ('Use '+@db+';Exec f$.CleanupLibraryObjects')
  -- Exec f$.FlushDataFromDb 'GPI_REF'
  -- Exec f$.FlushDataFromDb 'JADE_REF'
  -- Exec f$.FlushDataFromDb 'PAIE_REF'
End
GO
exec f$.DropObj 'f$.RemoveAllHeadingAndTailingCrLf'
GO
--f$SignatureForCleanup
Create Function f$.RemoveAllHeadingAndTailingCrLf(@txt nvarchar(max))
Returns Nvarchar(max)
as
Begin

  Declare @tTxt nvarchar(max) = @txt

  Declare @way int = 1;
  Declare @startIndex int

  While (1=1)
  Begin
    If @way =1
    Begin
      Set @tTxt= LTrim(@tTxt)
      Set @startIndex=1
    End
    Else 
    Begin
      Set @tTxt= RTrim(@tTxt)
      Set @startIndex=Len(@tTxt) - 1
    End
   
    If SUBSTRING(@tTxt, @startIndex, 2) = (nchar(13)+nchar(10))
    Begin
      Set @tTxt = STUFF(@tTxt, @startIndex, 2, '')
    End
    Else
    Begin
      If @way = 1
        Set @way = -1
      else
        break;
    End

  End

  return(@tTxt)
End
GO

EXEC f$.DropObj 'f$.SchemaInfoForCompare';
GO
---------------------------------------------------------------------
-- Function that script the definition of all object for the purpose to compare 
---------------------------------------------------------------------
--f$SignatureForCleanup
Create Function f$.SchemaInfoForCompare ()
returns table
as 
return 
(
With 
  SqlObjects as
  (
    Select 
      'Column' as TypeObj
    , C.FullTbName+'.'+cn as CleObj
    , ColDefAndCN + ' | ' + IsNull(collation_name, Convert(nvarchar(100), DATABASEPROPERTYEX(db_name(), 'Collation'))) as DefObj
    From 
      f$.ColInfo(null, null) as C

    Union All

    Select 
      'Index' as TypeObj
    , I.FullTbName+'.'+I.idxName
    , I.CreateIndexWithoutWithClause collate database_default
    From
      f$.IndexInfo(null, null) as I

    Union All

    Select
      'ForeignKey' as TypeObj
    , F.FullTbName+'.'+F.FkName as CleObj
    , F.AddForeignKey as DefObj
    From
      f$.ForeignKeyInfo(null) F

    Union All

    Select 
      type_desc as TypeObj
    , '[' + Schema_name(o.schema_id) + '].[' + o.name + ']' as CleObj
    , f$.RemoveAllHeadingAndTailingCrLf(m.definition) as DefObj
    From 
      sys.sql_modules m
      join
      sys.objects o
      On o.object_id=m.object_id
    Where '[' + Schema_name(o.schema_id) + '].[' + o.name + ']' <> '[f$].[RunScript]' -- Cette fonction pose problème à cause du commentaire qui est remplacer par l'appel à la fonction 

  )

  Select * 
  From 
    SqlObjects
)
GO
Exec f$.DropObj 'f$.DbCloningFromRemoteInstance'
GO
--f$SignatureForCleanup
Create Procedure f$.DbCloningFromRemoteInstance @LinkedServer sysname, @remoteDb sysname, @LocalDb sysname
--f$.DbCloningFromRemoteInstance test, test, test
as
Begin
  --exec f$.ScriptPrmPersistenceForSp 'f$.DbCloningFromRemoteInstance'
  
  If Object_id('Tempdb..#Prm') IS NOT NULL Drop table #Prm
  --Select  @LinkedServer as LinkedServer, @remoteDb as remoteDb, @LocalDb as LocalDb Into #Prm
  --This commented sample below makes easy to create a #Prm table to test sp parts.
  Select  
    CAST (N'vCsgrics\sql' As sysname) as LinkedServer
  , CAST (N'DEV_Achat_CS2' As sysname) as remoteDb
  , CAST (N'DEV_Achat_CS2' As sysname) as LocalDb Into #Prm

  Set nocount on
  If Not Exists(Select * From #Prm join sys.servers S on S.name = #Prm.LinkedServer collate database_default)
  Begin
    declare @Srv sysname; Select @srv = #Prm.LinkedServer From #Prm
    Raiserror('Define "%s" linked server with local credentials mapping to sysadmin account on "%s"', 11, 1, @Srv, @Srv)
    return
  End  

  insert into f$.ScriptToRun (sql, seq)
  Select r0.s, 1
  From 
    #prm
    /*===isSysadminTest===
    Set nocount on
    Exec
    (
    '
    Declare @login sysname; Set @login = suser_sname()
    If IS_SRVROLEMEMBER(''sysadmin'')=0 Raiserror (''Account %s is not granted sysadmin rights'', 11, 1, @login)
    '
    ) at [#LinkedServer#]
    ===isSysadminTest===*/
    cross apply f$.GetCommentFromBatch('===isSysadminTest===') as B
    Cross Apply f$.iReplace(B.BatchComment, '#LinkedServer#', #Prm.LinkedServer) as r0
  exec f$.RunScript @Silent=1

  insert into f$.ScriptToRun (sql, seq)
  Select r0.s, 1
  From 
    #prm
    /*===TestGricsFP4Tsql===
    Exec (' If DB_ID(''GricsFp4Tsql'') IS NULL Raiserror (''Execute script GricsFp4TSql on #LinkedServer#'', 11, 1) ' ) at [#LinkedServer#]
    ===TestGricsFP4Tsql===*/
    cross apply f$.GetCommentFromBatch('===TestGricsFP4Tsql===') as B
    Cross Apply f$.iReplace(B.BatchComment, '#LinkedServer#', #Prm.LinkedServer) as r0
    Cross Apply f$.iReplace(r1.s, '#remoteDb#', #Prm.remoteDb) as r0
  exec f$.RunScript @Silent=1

  insert into f$.ScriptToRun (sql, seq)
  Select r1.s, 1
  From 
    #prm
    /*===TestAndPrepRemoteDb===
    Exec (' If DB_ID(''#remoteDb#'') IS NULL Raiserror (''Database #remoteDb# is not found on #LinkedServer#'', 11, 1) ' ) at [#LinkedServer#]
    Exec ('Use GricsFp4TSQL; Exec f$.CleanupSchemaf$OnOtherDb ''#remoteDb#'' ' ) at [#LinkedServer#]
    Exec ('Use GricsFp4TSQL; Exec f$.AutoDuplicateToolsToDb ''#remoteDb#'' ' ) at [#LinkedServer#]
    ===TestAndPrepRemoteDb===*/
    cross apply f$.GetCommentFromBatch('===TestAndPrepRemoteDb===') as B
    Cross Apply f$.iReplace(B.BatchComment, '#LinkedServer#', #Prm.LinkedServer) as r0
    Cross Apply f$.iReplace(r0.s, '#remoteDb#', #Prm.remoteDb) as r1
  exec f$.RunScript @Silent=1

  Exec f$.DropObj 'dbo.TmpRemoteTableInfo'
  Exec f$.DropObj 'dbo.RemoteObjInfo'
  Exec f$.DropObj 'dbo.RemoteCodeObjDef'
  insert into f$.ScriptToRun (sql, seq)
  Select r1.s, 1
  From 
    #prm
    /*===GetRemoteTableInfo===
    Select * Into dbo.TmpRemoteTableInfo From OpenQuery([#LinkedServer#], 'Select * From [#remoteDb#].f$.TableInfo(null) ' ) as R
    Select * Into dbo.RemoteObjInfo 
    From OpenQuery([#LinkedServer#], 'Select Object_schema_name(* From [#remoteDb#].sys.Objects ' ) as R
    Select * Into dbo.TmpRemoteTableInfo From OpenQuery([#LinkedServer#], 'Select * From [#remoteDb#].f$.TableInfo(null) ' ) as R
    ===GetRemoteTableInfo===*/
    cross apply f$.GetCommentFromBatch('===GetRemoteTableInfo===') as B
    Cross Apply f$.iReplace(B.BatchComment, '#LinkedServer#', #Prm.LinkedServer) as r0
    Cross Apply f$.iReplace(r0.s, '#remoteDb#', #Prm.remoteDb) as r1
  exec f$.RunScript @Silent=0


--Select r.*
--From 
--  (select distinct type_desc From sys.objects) as r1
--  cross apply f$.iQReplace(', ("#type_desc#", "#type_desc#")', '#type_desc#', type_desc) as r
--order by type_desc

;With 
  ObjTypeDescMap as
  (
  Select *
  From 
    (
    Values 
      (0, 'AGGREGATE_FUNCTION', 'AGGREGATE_FUNCTION')
    , (0, 'CHECK_CONSTRAINT', 'CHECK_CONSTRAINT')
    , (0, 'CLR_SCALAR_FUNCTION', 'CLR_SCALAR_FUNCTION')
    , (0, 'CLR_STORED_PROCEDURE', 'CLR_STORED_PROCEDURE')
    , (0, 'CLR_TABLE_VALUED_FUNCTION', 'CLR_TABLE_VALUED_FUNCTION')
    , (0, 'CLR_TRIGGER', 'CLR_TRIGGER')
    , (0, 'DEFAULT_CONSTRAINT', 'DEFAULT_CONSTRAINT')
    , (0, 'EXTENDED_STORED_PROCEDURE', 'EXTENDED_STORED_PROCEDURE')
    , (0, 'FOREIGN_KEY_CONSTRAINT', 'FOREIGN_KEY_CONSTRAINT')
    , (0, 'INTERNAL_TABLE', 'INTERNAL_TABLE')
    , (0, 'PLAN_GUIDE', 'PLAN_GUIDE')
    , (0, 'PRIMARY_KEY_CONSTRAINT', 'PRIMARY_KEY_CONSTRAINT')
    , (1, 'REPLICATION_FILTER_PROCEDURE', 'REPLICATION_FILTER_PROCEDURE')
    , (1, 'RULE', 'RULE')
    , (0, 'SEQUENCE_OBJECT', 'SEQUENCE_OBJECT')
    , (0, 'SERVICE_QUEUE', 'SERVICE_QUEUE')
    , (1, 'SQL_INLINE_TABLE_VALUED_FUNCTION', 'FUNCTION')
    , (1, 'SQL_SCALAR_FUNCTION', 'FUNCTION')
    , (1, 'SQL_STORED_PROCEDURE', 'PROCEDURE')
    , (1, 'SQL_TABLE_VALUED_FUNCTION', 'FUNCTION')
    , (1, 'SQL_TRIGGER', 'TRIGGER')
    , (0, 'SYNONYM', 'SYNONYM')
    , (0, 'SYSTEM_TABLE', 'SYSTEM_TABLE')
    , (0, 'TABLE_TYPE', 'TABLE_TYPE')
    , (0, 'UNIQUE_CONSTRAINT', 'UNIQUE_CONSTRAINT')
    , (1, 'USER_TABLE', 'TABLE')
    , (1, 'VIEW', 'VIEW')
    ) as t (handledObjType, type_desc, TypeForDropCreateAlter)
  )
select OBJECT_SCHEMA_NAME(Mod.object_id, db_id()), T.TypeForDropCreateAlter, OBJ.Name, obj.type, Obj.type_desc, T.TypeForDropCreateAlter
from 
  sys.sql_modules as Mod
  JOIN sys.Objects as Obj
  On Obj.object_id = Mod.object_id
  LEFT JOIN ObjTypeDescMap as T
  ON T.type_desc = Obj.type_desc
order by T.type_desc



End
GO
---------------------------------------------------------------------------------------------------------------------------------
-- Cette fonction génère du code qui effectue plusieurs actions pour la gestion des erreur de validations.
-- Elle isole premièrement le texte du commentaire de son lot de requête délimité par la chaîne passé en paramètre.
--
-- Dans ce texte se trouve la partie du informative du message à afficher si des erreurs de validation ont été enregistrées
-- Du plus un select a exécuter y est spécifié.  Il sert à retourner des données sur les problèmes de validation.
--
-- Si ce select peut retourner des rangées informatives supplémentaires sur l'erreur parce qu'il y en a, la situation 
-- d'erreur est considéré comme vérifiée et cet erreur est enregistrée.  On utilise cette fonction seulement pour 
-- enregistrer les erreurs trouvées dans le but de les afficher plus tard par F.AfficheSommaireErreursvalidationEtStoppeSurErreur 
--
-- Exemple d'appel  : Noter l'utilisation de la balise ListeTabDiff pour marquer le commentaire et son passage en paramètre
-- Une balise ne doit être utilisée qu'une fois dans un lot sql ou une stored procédure
-- En dernier lieu il faut marquer le Select le From et le Order by principal en les précédant du caractère "|"
-- car des manipulations de syntaxe se font autour de ces éléments

-- Cette fonction ne fait que mémoriser le message et est appellée parfois directement
-- par F$.RecordErrMsgIfResultSetAfficheEtStoppe. D'ailleurs c'est cette dernière qui appelle F$.RecordErrMsgIfResultSet
-- sans select dans le commentaire pour émettre le message inconditionnellement

/*
  /*ListeTabDiff
  Il y a des tables manquantes par rapport à la version officielle supportée
  Vérifier la version supportée, et mettre à jour les bases de données sources.|
  Select * |from SomeTableResults
  Order By 1
  ListeTabDiff*/
  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From F$.RecordErrMsgIfResultSet('ListeTabDiff', 'Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0

  /*AlwaysRecordThisMessage
  There are missing tables in comparison to official database version.
  Check version of source databases
  AlwaysRecordThisMessage*/
  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From F.RecordErrMsgIfResultSet('AlwaysRecordThisMessage')
  Exec f$.RunScript @printOnly=0
*/
--
---------------------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.RecordErrMsgIfResultSet'
GO
--f$SignatureForCleanup
create function f$.RecordErrMsgIfResultSet (@MsgTag sysname, @MsgTable sysname)
returns Table
as
Return
(
  /*TstMsg
  Message that span
  many lines|
  Select * |from ATableThatHasSomeMsg  Order By 1
  tstMsg*/

  /*---DoCreateAndInsertIntoTable---
  Set NoCount On
  If Schema_Id(f$.UnQuoteName('#MsgTableSch#')) IS NULL 
    Exec ('Create Schema #MsgTableSch# Authorization Dbo');

  If Object_id('#MsgTable#') IS NULL 
    Create Table #MsgTable# (Ordre Int Identity, CommentTag sysname, Msg Nvarchar(max), SelectToDo Nvarchar(max) NULL)

  #IfSelectHasResultSetsRecordMessage#

  -- only way to work around double quoting complexity it to put it in comment
  -- and turn this comment into columns with GetCommentFromBatch

  /*!Msg!#TxtMsg#!Msg!*/
  /*!Select!#TxtSelect#!Select!*/

  Insert into #MsgTable# (CommentTag, Msg, SelectToDo)
  Select '#MsgTag#', Msg.BatchComment, SelectPourDet.BatchComment
  From 
    f$.GetCommentFromBatch('!Msg!') as Msg
    Cross APPLY f$.GetCommentFromBatch('!Select!') as SelectPourDet

  ---DoCreateAndInsertIntoTable---*/
  
  --With PrmToCols (MsgTag, MsgTable) as (Select '---BuildFirstMsgOutputIntoMsgTableFromSelectResult---', Consts.ValidationMsgs())
  With PrmToCols (MsgTag, MsgTable) as (Select @MsgTag, @MsgTable) 
, Prm as 
  (
  Select
    P.MsgTag
  , QuoteName(isnull(PARSENAME (P.MsgTable, 3),db_name())) as DbMsgTable
  , QuoteName(isnull(PARSENAME (P.MsgTable, 2), SCHEMA_NAME ())) as MsgTableSch -- default to default schema name of the caller
  , QuoteName(isnull(PARSENAME (P.MsgTable, 1), '')) as MsgTableName
  From PrmToCols as P
  ) 
  --Select * From Prm 
, MsgParts as  
  (
  Select 
    P.MsgTag
  , P.MsgTableSch
  , DbMsgTable+'.'+MsgTableSch+'.'+MsgTableName as FullyDbQualifiedMsgTable
  , Msg.Txt as TxtMsg
  , CleanFullSelect.s as TxtSelect, IfSelectHasResultSetsRecordMessage.s as IfSelectHasResultSetsRecordMessage
  From 
    Prm as P
    CROSS APPLY (Select BatchComment, Lg From f$.GetCommentFromBatch(P.msgTag) ) as CurExecBatch(Txt, Len)
    CROSS APPLY (Select charindex('|', CurExecBatch.Txt)) as StartQryPos(Pos)
    CROSS APPLY (Select Case When StartQryPos.Pos > 0 Then Stuff(CurExecBatch.Txt, 1, StartQryPos.Pos, '') Else '' End) as FullSelectIncludingPipeFrom(Txt)
    CROSS APPLY (Select Case When StartQryPos.Pos > 0 Then Stuff(CurExecBatch.Txt, StartQryPos.Pos, CurExecBatch.Len, '') Else CurExecBatch.Txt End) as Msg(Txt)
    CROSS APPLY f$.IReplace(FullSelectIncludingPipeFrom.Txt, '|From', 'Into #tmp From') as SelectInto
    CROSS APPLY f$.IReplace(FullSelectIncludingPipeFrom.Txt, '|', '') as CleanFullSelect
    CROSS APPLY f$.IReplace(Case When SelectInto.s <> '' Then '#SelectInto#; If @@rowcount=0 Return' Else '' End, '#SelectInto#', SelectInto.s) as IfSelectHasResultSetsRecordMessage
  )
  --Select * from MsgParts
  Select r6.s as Sql, 1 as seq
  From 
    MsgParts as P
    Cross Apply f$.GetCommentFromSqlObj(object_id('f$.RecordErrMsgIfResultSet'), '---DoCreateAndInsertIntoTable---') as C
    Cross Apply f$.iReplace (C.CommentContent, '#IfSelectHasResultSetsRecordMessage#', P.IfSelectHasResultSetsRecordMessage) as r1
    Cross Apply f$.IReplace (r1.s, '#TxtMsg#', P.TxtMsg) as r2
    Cross Apply f$.IReplace (r2.s, '#TxtSelect#', P.TxtSelect) as r3
    Cross Apply f$.iReplace (r3.s, '#MsgTable#', P.FullyDbQualifiedMsgTable) as r4
    Cross Apply f$.iReplace (r4.s, '#MsgTag#', P.MsgTag) as r5
    Cross Apply f$.iQReplace (r5.s, '#MsgTableSch#', P.MsgTableSch) as r6

  
  /* -- test1  -- to do test just select text up to 

  /*---BuildFirstMsgOutputIntoMsgTableFromSelectResult---
  Message that span 
  many lines|
  Select * |from (Select 'Here is some test result' as Output) as t Order By 1
  ---BuildFirstMsgOutputIntoMsgTableFromSelectResult---*/

  Exec f$.DropObj 'Msg.ValidationMsgs'
  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From F$.RecordErrMsgIfResultSet('---BuildFirstMsgOutputIntoMsgTableFromSelectResult---', 'Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0
  Select 'BuildFirstMsgOutputIntoMsgTableFromSelectResult' as Test, * from Msg.ValidationMsgs Order By 1
  If Exists(Select * From Msg.ValidationMsgs) Print 'BuildFirstMsgOutputIntoMsgTableFromSelectResult test succeed'

  /*BuildNoOutputIntoMsgTableFromSelectResult
  Message that span 
  many lines|
  Select * |from (Select 'Here is some test result' as Output where 1=0) as t Order By 1
  BuildNoOutputIntoMsgTableFromSelectResult*/

  Exec f$.DropObj 'Msg.ValidationMsgs'
  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From F$.RecordErrMsgIfResultSet('BuildNoOutputIntoMsgTableFromSelectResult', 'Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0
  If Not Exists(Select * From Msg.ValidationMsgs) Print 'BuildNoOutputIntoMsgTableFromSelectResult test succeed'

  /*---Check msg is recorded when there is no select---
  Message that span 
  many lines
  ---Check msg is recorded when there is no select---*/
  Exec f$.DropObj 'Msg.ValidationMsgs'
  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From F$.RecordErrMsgIfResultSet('---Check msg is recorded when there is no select---', 'Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0
  Select 'Check msg is recorded when there is no select' as Test, * from Msg.ValidationMsgs Order By 1
  If Exists(Select * From Msg.ValidationMsgs) Print 'Check msg is recorded when there is no select: test succeed'

  */

)
GO
---------------------------------------------------------------------------
-- This function calls F$.RecordErrMsgIfResultSet to record conditionnally a message into a msg table
-- (See F$.RecordErrMsgIfResultSet for more documentation)
-- If message recording occurs, this function display a message, run the select recorded with the message, 
-- and stop with a message which instruct to look at result pane to consult the error
---------------------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.StopScriptOnQueryResultsAndDisplayMessage'
GO
--f$SignatureForCleanup
Create Function f$.StopScriptOnQueryResultsAndDisplayMessage (@MsgTag sysname, @MsgTable sysname)
returns Table
as
Return
(
/*---ToGenFor-f$.StopScriptOnQueryResultsAndDisplayMessage---
    #f$.RecordErrMsgIfResultSet#

    -- Liste Subjects
    Declare @Msg Nvarchar(max), @SelectToDo Nvarchar(Max)
    Select Top 1 @Msg = M.Msg, @SelectToDo = M.SelectToDo
    From 
      #MsgTable# as M
    Order By Ordre Desc -- last message among those accumulated

    Truncate Table #MsgTable# -- Stop and clear
    -- make multiple consecutive newline a single one
    Select L.item as [Msg from #MsgTable#.#MsgTag#]
    From 
      f$.iReplace(@Msg, Nchar(10), '|') as r0
      Cross Apply f$.iReplace(r0.s, Nchar(13), '|') as r1
      Cross Apply f$.iReplace(r1.s, Nchar(10), '|') as r2
      Cross Apply f$.DedupSeqOfChars ('|', r2.s) as r3
      Cross Apply f$.SplitList('|', r3.s) as L
    Where L.item IS NOT NULL
    Order By seq
    -- liste détails de la table 
    If @SelectToDo IS NOT NULL
    Begin 
      Exec (@SelectToDo);
      Throw 51000, 'Processing stopped, look a results pane for informations about the error', 1
    End
---ToGenFor-f$.StopScriptOnQueryResultsAndDisplayMessage---*/
With 
  Prm as  
  (
  Select @MsgTag as MsgTag, @MsgTable as MsgTable, OBJECT_ID('f$.StopScriptOnQueryResultsAndDisplayMessage') MySelf
  )
  Select r2.s as Sql, 1 as seq
  From 
    Prm
    CROSS Apply f$.GetCommentFromSqlObj(MySelf, '---ToGenFor-f$.StopScriptOnQueryResultsAndDisplayMessage---') C
    CROSS APPLY f$.RecordErrMsgIfResultSet(Prm.MsgTag, @MsgTable) as E
    Cross Apply f$.IReplace (C.CommentContent, '#f$.RecordErrMsgIfResultSet#', E.Sql) as r0
    Cross Apply f$.iReplace (r0.s, '#MsgTag#', Prm.MsgTag) as r1
    Cross Apply f$.iQReplace (r1.s, '#MsgTable#', Prm.MsgTable) as r2
/*
  /*---BuildOutputIntoMsgTableFromSelectResultAndStop---
  Message that span 
  many lines|
  Select * |from (Select 'Here is some test result' as Output) as t Order By 1
  ---BuildOutputIntoMsgTableFromSelectResultAndStop---*/

  Exec f$.DropObj 'Msg.ValidationMsgs'
  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From f$.StopScriptOnQueryResultsAndDisplayMessage('---BuildOutputIntoMsgTableFromSelectResultAndStop---', 'Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0
  Print 'If this display appears the test failed'
*/
)
GO
---------------------------------------------------------------------------------------------------------------------------------
-- This function generate code to list cumulative messages, and says to execute Selects by listing them
-- We don't try to execute ourselfs, because SQL Management Studio has limitations on the number of results set it can display at once
-- This function create code to stop exec if it found some message to display
---------------------------------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'f$.DisplayErrorMsgSummaryAndStopOnError'
GO
--f$SignatureForCleanup
create function f$.DisplayErrorMsgSummaryAndStopOnError(@MsgTable sysname)
returns Table
as
Return
(
 /*---ToGenFor-f$.DisplayErrorMsgSummaryAndStopOnError---
 Declare @Msg Nvarchar(max), @SelectToDo Nvarchar(Max)
 ;With 
   MessagePartsToSort As
   (
   Select M.Ordre, L.Seq as Seq, "A" as SubSeq, L.item as MsgLine 
   From 
     #MsgTable# as M
     Cross Apply f$.iReplace(M.Msg, Nchar(10), "|") as r0
     Cross Apply f$.iReplace(r0.s, Nchar(13), "|") as r1
     Cross Apply f$.iReplace(r1.s, Nchar(10), "|") as r2
     Cross Apply f$.DedupSeqOfChars ("|", r2.s) as r3
     Cross Apply f$.SplitList("|", r3.s) as L
   Where L.item IS NOT NULL
   UNION ALL
   Select M.Ordre, 100 as Seq, "" as Subseq, "    Afficher les détails du conflits par la requête suivante:"
   From #MsgTable# as M
   Where replace(M.SelectToDo, "", "") <> ""
   UNION ALL
   Select M.Ordre, 101 as seq, "" as Subseq, "         "+M.SelectToDo
   From #MsgTable# as M
   Where replace(M.SelectToDo, "", "") <> ""
   )
 Select MsgLine
 From 
   MessagePartsToSort
 Order By Ordre, seq, SubSeq, MsgLine
 If @@rowcount > 0
 Begin
   Throw 51000, 'Processing stopped, look a results pane for informations about the error', 1
 End
 ---ToGenFor-f$.DisplayErrorMsgSummaryAndStopOnError---*/

  With 
    Prm as 
    (
    Select @MsgTable as MsgTable
    , OBJECT_ID('f$.DisplayErrorMsgSummaryAndStopOnError') as MySelf
    , '---ToGenFor-f$.DisplayErrorMsgSummaryAndStopOnError---' as CommentTag
    )
  Select r0.s as Sql, 1 as seq
  From 
    Prm
    Cross Apply f$.GetCommentFromSqlObj(Myself, CommentTag) as C
    Cross Apply f$.IQReplace (C.CommentContent, '#MsgTable#', MsgTable) as r0
/*
  /*---BuildFirstMsgOutputIntoMsgTableFromSelectResult---
  Message1 that span 
  many lines|
  Select * |from (Select 'Here is some test result' as Output) as t Order By 1
  ---BuildFirstMsgOutputIntoMsgTableFromSelectResult---*/

  Exec f$.DropObj 'Msg.ValidationMsgs'
  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From F$.RecordErrMsgIfResultSet('---BuildFirstMsgOutputIntoMsgTableFromSelectResult---', 'Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0

  /*---BuildSecondMsgOutputIntoMsgTableFromSelectResult---
  Message2 that span 
  many lines|
  Select * |from (Select 'Here is some test result' as Output) as t Order By 1
  ---BuildSecondMsgOutputIntoMsgTableFromSelectResult---*/

  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From F$.RecordErrMsgIfResultSet('---BuildSecondMsgOutputIntoMsgTableFromSelectResult---', 'Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0

  Insert into f$.ScriptToRun (Sql, Seq)
  Select Sql, Seq From f$.DisplayErrorMsgSummaryAndStopOnError('Msg.ValidationMsgs')
  Exec f$.RunScript @printOnly=0
  Print 'If this message displays, the test failed'

*/
)
GO
------------------------------------------------------------------------------------
-- YourSqlDba specific code
------------------------------------------------------------------------------------
GO
-- Adjust SQL Server error logs archive to maximum of 30 
Set nocount On 
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs', REG_DWORD, 30
GO
If Schema_id('Log') IS NULL Exec ('Create schema Log authorization dbo');
Exec f$.RegisterLogTable 'Log.YourSqlDbaUpdate'
/*===ConfigureServerOptions===
Exec sp_configure '#OptionName#', #Value#
Reconfigure With Override
===ConfigureServerOptions===*/
Insert Into f$.ScriptToRun (Sql, Seq)
Select vSql2.Sql, Row_number() Over (Order by ActivationPriority, optionName) 
From 
  (
  Values 
    (-1, 'show advanced options', 1)
  , (0, 'clr enabled', 1)
  , (0, 'Agent XPs', 1)
  ) OptionsToChange (activationPriority, OptionName, Value)
  Cross Apply f$.GetCommentFromBatch('===ConfigureServerOptions===') as B
  Cross Apply (Select Sql = Replace(B.BatchComment, '#OptionName#', optionName)) as vSql1
  Cross Apply (Select Sql = Replace(vSql1.Sql, '#Value#', Value)) as vSql2
Where 
  Not Exists
  (
  select *
  from  sys.configurations 
  Where name = OptionsToChange.OptionName
    And value_in_use = OptionsToChange.Value 
  )
Exec f$.RunScript @PrintOnly=0

-- If Sql Service Broker in not enabled on MSDB, enable it
Insert Into f$.ScriptToRun(Sql, Seq)
Select 'alter database msdb set enable_broker', 1
Where Not exists(select name, is_broker_enabled from sys.databases where name = 'msdb' and is_broker_enabled = 1)
Exec f$.RunScript @PrintOnly=0

/*===SaveYourSqlDbaUsefulData===
-- Temp table not created from previous execution
If Object_ID('TempDb..###Sch#_#Tbname#') IS NULL
  Select * Into ###Sch#_#Tbname# from YourSqlDba.#Sch#.#TbName#
===SaveYourSqlDbaUsefulData===*/

/*===RedoSaveYourSqlDbaUsefulData===
If Not Exists (Select * From ###Sch#_#Tbname#)
Begin
  Drop Table ###Sch#_#Tbname#
  Select * Into ###Sch#_#Tbname# from YourSqlDba.#Sch#.#TbName#
End
===RedoSaveYourSqlDbaUsefulData===*/

;With
  TemplateExecOrder as
  (
  Select SaveTemplate.BatchComment as Template, 1 as MainExecOrderSeq
  From f$.GetCommentFromBatch('===SaveYourSqlDbaUsefulData===') as SaveTemplate
  UNION ALL
  Select RedoSaveTemplate.BatchComment as Template, 2 as MainExecOrderSeq
  From f$.GetCommentFromBatch('===RedoSaveYourSqlDbaUsefulData===') as RedoSaveTemplate
  ) 
, TablesAndTemplate as
  (
  Select *
  From 
    (
    Values ('Maint', 'JobLastBkpLocations'), ('Maint', 'JobSeqCheckDb'), ('Mirroring', 'TargetServer')
         , ('Maint', 'JobSeqUpdStat'), ('Maint', 'NetworkDrivesToSetOnStartup') 
    ) as T (Sch, tbName)
    CROSS JOIN TemplateExecOrder
  )
Insert Into f$.ScriptToRun (Sql, Seq)
Select vSql2.Sql, Row_number() Over (Order by MainExecOrderSeq, tbName)
From 
  TablesAndTemplate
  Cross Apply (Select Sql = Replace(Template, '#TbName#', tbName)) as vSql1
  Cross Apply (Select Sql = Replace(vSql1.Sql, '#Sch#', Sch)) as vSql2
Where 
  Object_id(Sch+'.'+tbName) IS NOT NULL
Exec f$.RunScript @PrintOnly=0

If Object_id('tempdb..#YourSqlDbaSchemas') Is Not NULL Drop table #YourSqlDbaSchemas
Select schemaName Into #YourSqlDbaSchemas
From 
  (
  Values 
    ('Audit '), ('yAudit '), ('Export '), ('yExport '), ('yExecNLog')
  , ('Install '), ('yInstall ')
  , ('Maint '), ('yMaint ')
  , ('Mirroring '), ('yMirroring ')
  , ('PerfMon '), ('yPerfMon ')
  , ('Upgrade'), ('yUpgrade')
  , ('Tools '), ('yUtl ')
  ) Schemas (SchemaName)

Insert Into f$.ScriptToRun (Sql, Seq)
Select DropObjs.stmt, Row_number() Over (Order by schemaName) 
From 
  #YourSqlDbaSchemas as Schs
  JOIN sys.Objects as Obj On Obj.Schema_id = Schema_id(Schs.SchemaName)
  Cross Apply f$.GenDropObj (f$.FullObjName(Obj.Object_id), 1) as DropObjs
Where 
     Obj.type_desc Like '%USER%TABLE%'
  Or Obj.type_desc Like '%PROCEDURE%'
  Or Obj.type_desc Like '%FUNCTION%'
  Or Obj.type_desc Like '%VIEW%'
  Or Obj.type_desc Like '%SYNONYM%'
Exec f$.RunScript @PrintOnly=0

Insert Into f$.ScriptToRun (Sql, Seq)
Select vSql.Sql, Row_number() Over (Order by schemaName) 
From 
  #YourSqlDbaSchemas
  Cross Apply (Select SqlTemplate='Drop schema #SchemaName#') as vSqlTemplate
  Cross Apply (Select Sql = Replace(SqlTemplate, '#SchemaName#', Schemaname)) as vSql
Where Schema_id(SchemaName) IS NOT NULL
Exec f$.RunScript @PrintOnly=0

Insert Into f$.ScriptToRun (Sql, Seq)
Select vSql.Sql, Row_number() Over (Order by schemaName) 
From 
  #YourSqlDbaSchemas
  Cross Apply (Select SqlTemplate='Create schema #SchemaName# authorization dbo') as vSqlTemplate
  Cross Apply (Select Sql = Replace(SqlTemplate, '#SchemaName#', Schemaname)) as vSql
Exec f$.RunScript @PrintOnly=0

GO
-- Create YourSqlDba login, with unknown password.  If required DBA can change it.
Insert into f$.ScriptToRun(Sql, Seq)
Select vSql.Sql, 1
From 
              (Select hash=HASHBYTES('SHA1', convert(nvarchar(100),newid()))) as vHash
  Cross Apply (Select RandomHexString=convert(nvarchar(400), hash, 2)) as vRandomHexString
  Cross Apply (Select unknownPwd=Convert(nvarchar(100),RandomHexString)) as vUnknownPwd
  /*===CreateLoginYourSqlDba===
    create login Yoursqldba 
    With Password = '#unknownPwd#'
    , DEFAULT_DATABASE = YourSqlDba
    , CHECK_EXPIRATION = OFF
    , CHECK_POLICY = OFF
    , DEFAULT_LANGUAGE=US_ENGLISH;  
  ===CreateLoginYourSqlDba===*/  
  Cross Apply f$.GetCommentFromBatch('===CreateLoginYourSqlDba===') as B
  Cross Apply (Select Sql=Replace(B.batchComment, '#unknownPwd#', unknownPwd)) as vSql
Where SUSER_SID('YourSqlDba') IS NULL
Exec f$.RunScript @PrintOnly=0
GO
Exec sp_addsrvrolemember @loginame= 'YourSqlDba' , @rolename = 'sysadmin'
GO
/*===MakeYourSqlDbaLoginOwnerOfYourSqlDbaDatabase===
ALTER AUTHORIZATION ON Database::[YourSQLDba] To [YourSqlDba]
ALTER Database YourSqlDba Set TRUSTWORTHY ON
GRANT EXTERNAL ACCESS ASSEMBLY TO YourSQLDba
===MakeYourSqlDbaLoginOwnerOfYourSqlDbaDatabase===*/
Insert into f$.ScriptToRun (sql, seq)
Select B.BatchComment, 1
from 
  f$.GetCommentFromBatch('===MakeYourSqlDbaLoginOwnerOfYourSqlDbaDatabase===') as B
Exec f$.RunScript @PrintOnly=0
GO
ALTER DATABASE YourSQLDba SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
GO
ALTER DATABASE YourSQLDba SET NEW_BROKER WITH ROLLBACK IMMEDIATE;
GO
IF  EXISTS (SELECT * FROM sys.assemblies asms WHERE asms.name = N'YourSqlDba_ClrExec')
  DROP ASSEMBLY [YourSqlDba_ClrExec]
GO
/****** Object:  SqlAssembly [YourSqlDba_ClrExec]    Script Date: 08/28/2012 16:04:35 ******/
CREATE ASSEMBLY [YourSqlDba_ClrExec] 
AUTHORIZATION [dbo]
FROM 0x4D5A90000300000004000000FFFF0000B800000000000000400000000000000000000000000000000000000000000000000000000000000000000000800000000E1FBA0E00B409CD21B8014CCD21546869732070726F6772616D2063616E6E6F742062652072756E20696E20444F53206D6F64652E0D0D0A2400000000000000504500004C010300DC98D5520000000000000000E00002210B010B000018000000060000000000000E360000002000000040000000000010002000000002000004000000000000000400000000000000008000000002000000000000030040850000100000100000000010000010000000000000100000000000000000000000B43500005700000000400000D003000000000000000000000000000000000000006000000C0000007C3400001C0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000080000000000000000000000082000004800000000000000000000002E7465787400000014160000002000000018000000020000000000000000000000000000200000602E72737263000000D00300000040000000040000001A0000000000000000000000000000400000402E72656C6F6300000C0000000060000000020000001E00000000000000000000000000004000004200000000000000000000000000000000F035000000000000480000000200050068240000141000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000133002006F00000001000011000F00281100000A0A0614FE0116FE01130511052D0A14281200000A13042B4C731300000A0B160D2B240006096F1400000A0C08281500000A130511052D0A0007086F1600000A2600000917580D09066F1700000AFE04130511052DCD076F1800000A281200000A13042B0011042A001B300200610000000200001100731900000A0A06026F1A00000A6F1B00000A00731300000A0B07731C00000A0C0008731D00000A0D09176F1E00000A0006096F1F00000A0000DE120814FE01130511052D07086F2000000A00DC00076F1800000A281200000A13042B0011042A00000001100000020021001B3C0012000000001E02282200000A2A1B300500A9010000030000110002167D020000047201000070732300000A0B00046F2400000A6F2500000A1304384601000011046F2600000A74270000010C00086F2700000A14FE01130511053A2501000000086F2700000A0A086F2800000A16FE0116FE01130511052D0F0007066F2900000A260038FB00000000086F2800000A1F0AFE0216FE01130511053A9200000000086F2A00000A16FE0216FE01130511052D20007203000070086F2A00000A8C28000001086F2B00000A282C00000A0D002B080072010000700D000772370000701B8D010000011306110616086F2D00000A8C28000001A2110617086F2800000A8C29000001A2110618086F2E00000A8C29000001A211061906A211061A09A211066F2F00000A26076F3000000A26002B2C0007728F000070086F2800000A8C29000001086F2E00000A8C29000001066F3100000A26076F3000000A2600086F2800000A027B02000004FE0216FE01130511052D0E0002086F2800000A7D020000040000000011046F3200000A130511053AAAFEFFFFDE1D110475220000011307110714FE01130511052D0811076F2000000A00DC0002076F1800000A7D010000042A000000411C000002000000210000005D0100007E0100001D000000000000001B3003000201000004000011141304730500000613050072DB000070733300000A0B0000076F3400000A0007176F3500000A000711042D111105FE0606000006733600000A13042B0011046F3700000A00720D01007007733800000A250A130600110572010000707D010000041105167D02000004026F3900000A733A00000A0C061A6F3B00000A00066F3C00000A722901007002733D00000A6F3E00000A26066F3F00000A260411057B010000046F4000000A734100000A510311057B02000004284200000A810500000100DE14110614FE01130711072D0811066F2000000A00DC0000DE0E0D00096F4300000A734400000A7A0000DE120714FE01130711072D07076F2000000A00DC00002A000001280000020054006FC300140000000000001700C4DB000E3400000102001600D7ED0012000000001E02282200000A2A42534A4201000100000000000C00000076322E302E35303732370000000005006C000000C0040000237E00002C0500001407000023537472696E677300000000400C00004001000023555300800D0000100000002347554944000000900D00008402000023426C6F620000000000000002000001571502000902000000FA25330016000001000000350000000300000002000000060000000900000045000000130000000400000001000000030000000100000000000A00010000000000060051004A000A00790064000A00950064000A00AF0064000A00B80064000A00F800DD0006004D012E01060071015F01060088015F010600A5015F010600C4015F010600DD015F010600F6015F01060011025F0106002C025F01060045022E01060059025F010600850272024B00990200000600C802A8020600E802A8020A001903DD0006005003440306005E034A0006006F034A000E00A40399030E00B00399030600D603CC030E00E30399030600F103CC030E00FC0399030E00160499030E001E049903060030044A000A004404DD000A009E0488040A00DE04880406000F05FC040A003505880406006E054A00060094054A000A00B90588040A00DA05C7050A00110688040A003C0688040A005206C7050A005C0658000A00780688040A009E0688040600CB064A000600D5064A000A00EA0688040600F706A80200000000010000000000010001000100100021000000050001000100030110005A04000005000100050006006D044A01060077044D01502000000000960083000A000100CC200000000096009C00110003002823000000009600C100180005006024000000008618D700240008004C21000000008618D700240008005421000000008600B60450010800000000000000000001000A01000000000000000001001701000001001B01020002002201020003005A0100000100D20400000200D9043100D70024003900D70024004100D7003B004900D7003B005100D7003B005900D7003B006100D7003B006900D7003B007100D7003B007900D7003B008100D70040008900D7003B009100D7004500A100D7004B00A900D7002400B100D700240011002E038E00110038039200B900D7002400C10065039800C90074039D00B9007E03A200C1008503A800090090038E00D100D70024001900BA03F600D100C703FB00E100D7000101E900D7000701E90007040D0101012804130111013C0424001901D70024000900D7002400B900D7003B002101F104580129011B055E0131012905640139013E058E0039014A056801B90054056C0139015F05A800390174058E00C1008205720139018905A800390199056801B900A3057901B90054058101B900A30586013101B0058F015101D7003B005901E70524005101EC0540006101D700A60151012C06AC016901D700B30121004706BB01C100D700C00171016806C60169018F06CD018901D700D3018101AB06D9017101AF06A800C100BF06BB012100D700C00129003803E20191013E058E009901D7003B00A901D700240020008300500024000B0028002E0023001B022E002B001B022E00330021022E007B0064022E001B0003022E004B001B022E0073005B022E00430030022E003B0003022E005B001B022E006B00520240008300B70044000B00280060000B01280163002B02FE0164000B00280084000B002800AC001A019301E80104800000010000000714466A00000000000006030000020000000000000000000000010041000000000002000000000000000000000001005800000000000200000000000000000000000100990300000000030002000000003C4D6F64756C653E00596F757253716C4462615F436C72457865632E646C6C0045786563757465596F757253716C446261436D64735468726F756768434C52006D73636F726C69620053797374656D004F626A6563740053797374656D2E446174610053797374656D2E446174612E53716C54797065730053716C537472696E6700436C725F52656D6F766543746C436861720053716C586D6C00436C725F586D6C5072657474795072696E740053716C43686172730053716C496E74333200436C725F45786563416E644C6F67416C6C4D736773002E63746F72004D6963726F736F66742E53716C5365727665722E5365727665720053716C4661636574417474726962757465006265666F726545736361706500586D6C0053716C436D64004D617853657665726974790053797374656D2E52756E74696D652E496E7465726F705365727669636573004F7574417474726962757465004D7367730053797374656D2E5265666C656374696F6E00417373656D626C795469746C6541747472696275746500417373656D626C794465736372697074696F6E41747472696275746500417373656D626C79436F6E66696775726174696F6E41747472696275746500417373656D626C79436F6D70616E7941747472696275746500417373656D626C7950726F6475637441747472696275746500417373656D626C79436F7079726967687441747472696275746500417373656D626C7954726164656D61726B41747472696275746500417373656D626C7943756C7475726541747472696275746500436F6D56697369626C6541747472696275746500417373656D626C7956657273696F6E4174747269627574650053797374656D2E446961676E6F73746963730044656275676761626C6541747472696275746500446562756767696E674D6F6465730053797374656D2E52756E74696D652E436F6D70696C6572536572766963657300436F6D70696C6174696F6E52656C61786174696F6E734174747269627574650052756E74696D65436F6D7061746962696C69747941747472696275746500596F757253716C4462615F436C72457865630053716C46756E6374696F6E417474726962757465006765745F56616C7565006F705F496D706C696369740053797374656D2E5465787400537472696E674275696C64657200537472696E67006765745F43686172730043686172004973436F6E74726F6C00417070656E64006765745F4C656E67746800546F537472696E670053797374656D2E586D6C00586D6C446F63756D656E7400586D6C52656164657200437265617465526561646572004C6F61640053797374656D2E494F00537472696E6757726974657200586D6C54657874577269746572005465787457726974657200466F726D617474696E67007365745F466F726D617474696E6700586D6C4E6F646500586D6C577269746572005772697465546F0049446973706F7361626C6500446973706F73650053716C50726F636564757265417474726962757465003C3E635F5F446973706C6179436C61737332004C6F63616C4D736773004C6F63616C4D617853657665726974790053797374656D2E446174612E53716C436C69656E740053716C496E666F4D6573736167654576656E7441726773003C436C725F45786563416E644C6F67416C6C4D7367733E625F5F300073656E64657200617267730053716C4572726F72436F6C6C656374696F6E006765745F4572726F72730053797374656D2E436F6C6C656374696F6E730049456E756D657261746F7200476574456E756D657261746F72006765745F43757272656E740053716C4572726F72006765745F4D657373616765006765745F436C61737300417070656E644C696E65006765745F4C696E654E756D62657200496E743332006765745F50726F63656475726500466F726D6174006765745F4E756D6265720042797465006765745F537461746500417070656E64466F726D6174004D6F76654E6578740053716C436F6E6E656374696F6E0053797374656D2E446174612E436F6D6D6F6E004462436F6E6E656374696F6E004F70656E007365745F46697265496E666F4D6573736167654576656E744F6E557365724572726F72730053716C496E666F4D6573736167654576656E7448616E646C6572006164645F496E666F4D6573736167650053716C436F6D6D616E64006765745F427566666572004462436F6D6D616E6400436F6D6D616E6454797065007365745F436F6D6D616E64547970650053716C506172616D65746572436F6C6C656374696F6E006765745F506172616D65746572730053716C506172616D657465720041646400457865637574654E6F6E517565727900546F43686172417272617900457863657074696F6E004170706C69636174696F6E457863657074696F6E0053716C457863657074696F6E00436F6D70696C657247656E6572617465644174747269627574650000000001003320006100740020006C0069006E00650020007B0030007D00200069006E002000700072006F00630020007B0031007D00200000574500720072006F00720020007B0030007D002C0020005300650076006500720069007400790020007B0031007D002C0020006C006500760065006C0020007B0032007D0020003A0020007B0033007D007B0034007D00004B5700610072006E0069006E00670020005300650076006500720069007400790020007B0030007D002C0020006C006500760065006C0020007B0031007D0020003A0020007B0032007D00003163006F006E007400650078007400200063006F006E006E0065006300740069006F006E003D0074007200750065003B00001B730070005F006500780065006300750074006500530071006C0000154000730074006100740065006D0065006E0074000000AA6CEFD529B9F442B1324A9955514A3C0008B77A5C561934E089060001110911090600011109120D0B00030112111011151012110320000112010001005408074D617853697A65FFFFFFFF042001010E042001010205200101114D04200101083D01000300540E044E616D6511436C725F52656D6F766543746C4368617254020F497344657465726D696E697374696301540209497350726563697365010320000E05000111090E04200103080400010203052001125D03032000080A07060E125D03081109023E01000300540E044E616D6512436C725F586D6C5072657474795072696E7454020F497344657465726D696E69737469630154020949735072656369736501042000126D05200101126D05200101125D05200101127905200101117D062001011280850D07061269125D127112751109022101000100540E044E616D6515436C725F45786563416E644C6F67416C6C4D73677302060E020608072002011C1280910520001280950520001280990320001C03200005052001125D0E0600030E0E1C1C072002125D0E1D1C042000125D082004125D0E1C1C1C032000021207080E125D12809D0E128099021D1C128089052002011C18062001011280B1072002010E1280A90420001D03052001011D03062001011180BD0520001280C1052002010E1C0820011280C51280C50500011115081507081280B51280A90E1280D11280B1120C1280B502040100000017010012596F757253716C4462615F436C724578656300000501000000000E0100094D6963726F736F667400002101001C436F7079726967687420C2A920536F6369C3A974C3A920475249435300000801000701000000000801000800000000001E01000100540216577261704E6F6E457863657074696F6E5468726F7773010000000000DC98D55200000000020000001C01000098340000981600005253445327609F2559CCC94D924DFC882D58C7C001000000633A5C45717569706553716C5C596F757253716C4462615C596F757253716C4462615F436C72457865635C6F626A5C44656275675C596F757253716C4462615F436C72457865632E7064620000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000DC3500000000000000000000FE350000002000000000000000000000000000000000000000000000F03500000000000000000000000000000000000000005F436F72446C6C4D61696E006D73636F7265652E646C6C0000000000FF250020001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100100000001800008000000000000000000000000000000100010000003000008000000000000000000000000000000100000000004800000058400000740300000000000000000000740334000000560053005F00560045005200530049004F004E005F0049004E0046004F0000000000BD04EFFE0000010000000100466A071400000100466A07143F000000000000000400000002000000000000000000000000000000440000000100560061007200460069006C00650049006E0066006F00000000002400040000005400720061006E0073006C006100740069006F006E00000000000000B004D4020000010053007400720069006E006700460069006C00650049006E0066006F000000B0020000010030003000300030003000340062003000000034000A00010043006F006D00700061006E0079004E0061006D006500000000004D006900630072006F0073006F00660074000000500013000100460069006C0065004400650073006300720069007000740069006F006E000000000059006F0075007200530071006C004400620061005F0043006C00720045007800650063000000000040000F000100460069006C006500560065007200730069006F006E000000000031002E0030002E0035003100320037002E00320037003200300036000000000050001700010049006E007400650072006E0061006C004E0061006D006500000059006F0075007200530071006C004400620061005F0043006C00720045007800650063002E0064006C006C000000000058001A0001004C006500670061006C0043006F007000790072006900670068007400000043006F0070007900720069006700680074002000A900200053006F0063006900E9007400E90020004700520049004300530000005800170001004F0072006900670069006E0061006C00460069006C0065006E0061006D006500000059006F0075007200530071006C004400620061005F0043006C00720045007800650063002E0064006C006C0000000000480013000100500072006F0064007500630074004E0061006D0065000000000059006F0075007200530071006C004400620061005F0043006C00720045007800650063000000000044000F000100500072006F006400750063007400560065007200730069006F006E00000031002E0030002E0035003100320037002E00320037003200300036000000000048000F00010041007300730065006D0062006C0079002000560065007200730069006F006E00000031002E0030002E0035003100320037002E00320037003200300036000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000C000000103600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
WITH PERMISSION_SET = SAFE
GO
EXEC sys.sp_addextendedproperty @name=N'SqlAssemblyProjectRoot', @value=N'C:\EquipeSql\YourSqlDba\YourSqlDba_ClrExec' , @level0type=N'ASSEMBLY',@level0name=N'YourSqlDba_ClrExec'
GO
CREATE PROCEDURE yExecNLog.Clr_ExecAndLogAllMsgs
	@SqlCmd nvarchar(max),
 @MaxSeverity Int Output,
	@Msgs nvarchar(max) OUTPUT
AS EXTERNAL NAME [YourSqlDba_ClrExec].[ExecuteYourSqlDbaCmdsThroughCLR].[Clr_ExecAndLogAllMsgs]
GO
Create Function yExecNLog.Clr_RemoveCtlChar (@beforeEscape nvarchar(max)) 
returns nvarchar(max)
as  EXTERNAL NAME [YourSqlDba_ClrExec].[ExecuteYourSqlDbaCmdsThroughCLR].[Clr_RemoveCtlChar]
GO
Create Function yExecNLog.Clr_XmlPrettyPrint (@Xml Xml) 
returns nvarchar(max)
as  EXTERNAL NAME [YourSqlDba_ClrExec].[ExecuteYourSqlDbaCmdsThroughCLR].Clr_XmlPrettyPrint
GO

-- Create assemblies and procedure and function that points to them
IF  EXISTS (SELECT * FROM sys.assemblies asms WHERE asms.name = N'YourSqlDba_ClrFileOp')
  DROP ASSEMBLY [YourSqlDba_ClrFileOp]
GO
/****** Object:  SqlAssembly [YourSqlDba_ClrFileOp]    Script Date: 03/15/2012 16:25:38 ******/
CREATE ASSEMBLY [YourSqlDba_ClrFileOp] AUTHORIZATION [dbo]
FROM 0x4D5A90000300000004000000FFFF0000B800000000000000400000000000000000000000000000000000000000000000000000000000000000000000800000000E1FBA0E00B409CD21B8014CCD21546869732070726F6772616D2063616E6E6F742062652072756E20696E20444F53206D6F64652E0D0D0A2400000000000000504500004C0103000894D5520000000000000000E00002210B010B000020000000060000000000001E3F0000002000000040000000000010002000000002000004000000000000000400000000000000008000000002000000000000030040850000100000100000000010000010000000000000100000000000000000000000D03E00004B00000000400000E803000000000000000000000000000000000000006000000C000000983D00001C0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000080000000000000000000000082000004800000000000000000000002E74657874000000241F0000002000000020000000020000000000000000000000000000200000602E72737263000000E8030000004000000004000000220000000000000000000000000000400000402E72656C6F6300000C0000000060000000020000002600000000000000000000000000004000004200000000000000000000000000000000003F0000000000004800000002000500C8290000D013000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001B3003004B0000000100001100178D1A0000010C08161F5C9D080A0272010000706F1100000A16FE010D092D0902066F1200000A10000002281300000A260372050000705100DE0D0B0003076F1400000A5100DE00002A000110000000002A00123C000D1E0000011B3003004B0000000100001100178D1A0000010C08161F5C9D080A0272010000706F1100000A16FE010D092D0902066F1200000A10000002281500000A000372050000705100DE0D0B0003076F1400000A5100DE00002A000110000000002A00123C000D1E0000011B3004005C0000000100001100178D1A0000010C08161F5C9D080A0272010000706F1100000A16FE010D092D0902066F1200000A1000000202281600000A720100007003281700000A281800000A000472050000705100DE0D0B0004076F1400000A5100DE00002A0110000000002A00234D000D1E0000011B300300A10000000200001100731A00000A0B178D1A00000113061106161F5C9D11060C0272010000706F1100000A16FE01130711072D0902086F1200000A1000000203281B00000A0A000613081613092B19110811099A0D0709281C00000A6F1D00000A26110917581309110911088E69FE04130711072DD900DE27130400076F1E00000A000772070000706F1D00000A260711046F1400000A6F1D00000A2600DE00000713052B0011052A00000001100000000035003C7100271E0000011330020016000000030000110002281F00000A0A0306282000000A732100000A512A00001B300300400100000400001100731A00000A0B178D1A00000113081108161F5C9D110813040272010000706F1100000A16FE01130911092D0A0211046F1200000A1000000203281B00000A0A0006130A16130B2B65110A110B9A1305001105732200000A0D1202096F2300000A7D010000041202096F2400000A7D020000041202096F2500000A7D030000041202096F2600000A7D040000041202096F2700000A7D0500000407088C020000026F1D00000A2600110B1758130B110B110A8E69FE04130911092D8D00DE78130600076F1E00000A00120272070000707D01000004120272170000707D020000041202166A7D030000041202721F000070282800000A7D040000041202721F000070282800000A7D0500000407088C020000026F1D00000A26120211066F1400000A7D0100000407088C020000026F1D00000A2600DE00000713072B0011072A011000000000370088BF00781E0000011330020067000000050000110002A5020000020A0312007B01000004282000000A732100000A510412007B02000004282000000A732100000A510512007B03000004732900000A81060000010E0412007B04000004732A00000A81070000010E0512007B05000004732A00000A81070000012A001B300200260000000600001100000302282B00000A520472050000705100DE100A0003165204066F1400000A5100DE00002A00000110000000000100131400101E0000011B3002002200000006000011000002282C00000A000372050000705100DE0D0A0003066F1400000A5100DE00002A000001100000000001001213000D1E0000011B3003007B0000000700001100178D1A00000113041104161F5C9D11040B0272010000706F1100000A16FE01130511052D0902076F1200000A1000000203281B00000A0A000613061613072B13110611079A0C08282C00000A00110717581307110711068E69FE04130511052DDF0472050000705100DE0D0D0004096F1400000A5100DE00002A000110000000002F003D6C000D1E0000011B300400BA0000000800001100178D1A00000113041104161F5C9D11040B0272010000706F1100000A16FE01130511052D0902076F1200000A10000002723500007003282D00000A281B00000A0A000613061613072B48110611079A0C081B8D1B000001130811081602A21108177201000070A211081808282E00000AA2110819723B000070A211081A04A21108282F00000A283000000A00110717581307110711068E69FE04130511052DAA0572050000705100DE0D0D0005096F1400000A5100DE00002A00000110000000002F007CAB000D1E0000011B3004002F000000060000110000020202281C00000A036F3100000A283000000A000472050000705100DE0D0A0004066F1400000A5100DE00002A0001100000000001001F20000D1E0000011B300300310000000900001100178D1A0000010C08161F5C9D080A000203283200000A000472050000705100DE0D0B0004076F1400000A5100DE00002A0000000110000000000F001322000D1E0000011B3004005C0000000100001100178D1A0000010C08161F5C9D080A0372010000706F1100000A16FE010D092D0903066F1200000A1001000203720100007002281C00000A281700000A283000000A000472050000705100DE0D0B0004076F1400000A5100DE00002A0110000000002A00234D000D1E0000011B300400A90000000700001100178D1A00000113041104161F5C9D11040B0272010000706F1100000A16FE01130511052D0902076F1200000A10000472010000706F1100000A16FE01130511052D0904076F1200000A1002000203281B00000A0A000613061613072B24110611079A0C0804720100007008281C00000A281700000A283000000A00110717581307110711068E69FE04130511052DCE0572050000705100DE0D0D0005096F1400000A5100DE00002A0000000110000000004C004E9A000D1E0000011B3002002E0000000A000011000002732200000A0A03066F2500000A550472050000705100DE110B0003166A5504076F1400000A5100DE00002A000001100000000001001A1B00111E0000011B3002004D0000000B0000110003721F000070282800000A8103000001047205000070510002282B00000A16FE010B072D0E0302283300000A81030000012B0704723F0000705100DE0D0A0004066F1400000A5100DE00002A0000000110000000001800263E000D1E0000011B3002004D0000000B0000110003721F000070282800000A8103000001047205000070510002282B00000A16FE010B072D0E0302283400000A81030000012B0704723F0000705100DE0D0A0004066F1400000A5100DE00002A0000000110000000001800263E000D1E0000011B30020023000000060000110004720500007051000203283500000A0000DE0D0A0004066F1400000A5100DE00002A0001100000000008000C14000D1E0000011B30020023000000060000110004720500007051000203283600000A0000DE0D0A0004066F1400000A5100DE00002A0001100000000008000C14000D1E0000011E02283700000A2A42534A4201000100000000000C00000076322E302E35303732370000000005006C00000050060000237E0000BC0600006007000023537472696E6773000000001C0E000060000000235553007C0E00001000000023475549440000008C0E00004405000023426C6F620000000000000002000001571502000900000000FA25330016000001000000260000000300000005000000150000003B000000370000001D0000000B000000010000000200000000000A0001000000000006005B0054000600650054000600900054000600F800E5000A00370122010A00730122010A007C0122010600D402B5020600970385030600AE0385030600CB0385030600EA03850306000304850306001C04850306003704850306005204850306006B04B50206007F0485030600AB0498044F00BF0400000600EE04CE0406000E05CE0406004105B50206005705B5020A007D0562050600930554000600980554000600BA05B0050600C405B0050600E20554000600FF05B0050A002106620506003606E50006005F0654000A007006220106008606B00506008F06B0050600EE06B00500000000010000000000010001000801100023000000050001000100010010002F00380009000600010006006C000A00060075000A00060083000D000600990010000600A60010005020000000009600B20014000100B820000000009600C300140003002021000000009600D4001B0005009821000000009600040123000800582200000000960040012A000A007C22000000009600590123000C00D823000000009600880132000E004C24000000009600A901460014009024000000009600B80114001700D024000000009600C7011B0019006825000000009600D7014F001C004026000000009600F0011B0020008C26000000009600FF011B002300DC260000000096000C021B002600542700000000960019024F0029001C28000000009600270258002D0068280000000096003B0261003000D42800000000960053026100330040290000000096006A021B003600802900000000960081021B003900C02900000000861897026B003C00000001009D0202000200A802000001009D0202000200A802000001009D0200000200E10202000300A802000001009D0200000200EF0200000100FD02020002006C00000001009D0200000200EF0200000100FD02020002006C0002000300750002000400830002000500990002000600A600000001000103020002000A0302000300A80200000100010302000200A802000001009D0200000200EF0202000300A802000001009D0200000200190300000300260302000400A80200000100010300000200330302000300A802000001003F03000002004E0302000300A802000001003F0300000200620302000300A802000001009D0200000200EF0200000300620302000400A80200000100010302000200830002000300A80200000100010302000200990002000300A80200000100010302000200A60002000300A80200000100010300000200780302000300A80200000100010300000200780302000300A802410097026B00490097026F00510097026F00590097026F00610097026F00690097026F00710097026F00790097026F00810097026F00890097027400910097026F00990097027900A90097027F00B10097026B00B90097028400C90097026B00D9009F05A700D900A805AC00E100D205B200F100EC05B800E100F805E300F90004060501D90015060A01E1001C061101010197026B00090197026B00E10040068B01F90049060501090155069201090159066B0011016706AC0119017A06B10129009702B801210197026F0029019E06B8002901A706B8002101B506A7022901C006AB022901D206AB021101E306B00231009702D00239009702D5023101F306FB023101F805E300D90015067103F900FA060501D9001506770331011C061101D9001607AA0331011E07110131012307B00231013407B002310144071101310152071101110097026B00200083008A002E005300D9042E006B001C052E004300D9042E00630013052E00730025052E002300D9042E003B00EE042E001B00D9042E001300BF042E002B00DF042E003300BF0440008300C60060008300E8008000CB001701C000CB00C30100018300E002200183000503400183002003600183004C03800183008F03A0018300B003C0018300D203E0018300EB03000283000504200283002D04400283005704600283007A04800283009D04BC009701BF01B602DB0200033C037D03C9032504510404800000010000000714DC670000000000002C05000002000000000000000000000001004B000000000002000000000000000000000001001601000000000000003C4D6F64756C653E00596F757253716C4462615F436C7246696C654F702E646C6C0046696C6544657461696C730046696C654F70437300436C725F46696C654F7065726174696F6E73006D73636F726C69620053797374656D0056616C756554797065004F626A6563740046696C654E616D650046696C65457874656E73696F6E0046696C6553697A6542797465004461746554696D65004D6F6469666965644461746500437265617465644461746500436C725F437265617465466F6C64657200436C725F44656C657465466F6C64657200436C725F52656E616D65466F6C6465720053797374656D2E436F6C6C656374696F6E730049456E756D657261626C6500436C725F476574466F6C6465724C6973740053797374656D2E446174610053797374656D2E446174612E53716C54797065730053716C436861727300436C725F476574466F6C6465724C69737446696C6C526F7700436C725F476574466F6C6465724C69737444657461696C65640053716C496E7436340053716C4461746554696D6500436C725F476574466F6C6465724C69737444657461696C656446696C6C526F7700436C725F46696C6545786973747300436C725F44656C65746546696C6500436C725F44656C65746546696C657300436C725F4368616E676546696C65457874656E73696F6E7300436C725F52656E616D6546696C6500436C725F436F707946696C6500436C725F4D6F766546696C6500436C725F4D6F766546696C657300436C725F47657446696C6553697A654279746500436C725F47657446696C65446174654D6F64696669656400436C725F47657446696C65446174654372656174656400436C725F417070656E64537472696E67546F46696C6500436C725F5772697465537472696E67546F46696C65002E63746F7200466F6C64657250617468004572726F724D6573736167650053797374656D2E52756E74696D652E496E7465726F705365727669636573004F7574417474726962757465004E6577466F6C6465724E616D65005365617263685061747465726E006F626A0046696C65506174680046696C65457869737473466C6167004F6C64457874656E73696F6E004E6577457874656E73696F6E004E657746696C654E616D6500536F7572636546696C65506174680044657374696E6174696F6E46696C65506174680044657374696E6174696F6E466F6C646572506174680046696C65436F6E74656E74730053797374656D2E5265666C656374696F6E00417373656D626C795469746C6541747472696275746500417373656D626C794465736372697074696F6E41747472696275746500417373656D626C79436F6E66696775726174696F6E41747472696275746500417373656D626C79436F6D70616E7941747472696275746500417373656D626C7950726F6475637441747472696275746500417373656D626C79436F7079726967687441747472696275746500417373656D626C7954726164656D61726B41747472696275746500417373656D626C7943756C7475726541747472696275746500436F6D56697369626C6541747472696275746500417373656D626C7956657273696F6E4174747269627574650053797374656D2E446961676E6F73746963730044656275676761626C6541747472696275746500446562756767696E674D6F6465730053797374656D2E52756E74696D652E436F6D70696C6572536572766963657300436F6D70696C6174696F6E52656C61786174696F6E734174747269627574650052756E74696D65436F6D7061746962696C69747941747472696275746500596F757253716C4462615F436C7246696C654F70005374727563744C61796F7574417474726962757465004C61796F75744B696E64004D6963726F736F66742E53716C5365727665722E5365727665720053716C50726F636564757265417474726962757465004368617200537472696E6700456E647357697468005472696D456E640053797374656D2E494F004469726563746F7279004469726563746F7279496E666F004372656174654469726563746F727900457863657074696F6E006765745F4D6573736167650044656C6574650050617468004765744469726563746F72794E616D6500436F6E636174004D6F76650053716C46756E6374696F6E4174747269627574650041727261794C6973740047657446696C65730047657446696C654E616D650041646400436C65617200436F6E7665727400546F537472696E670053716C537472696E67006F705F496D706C696369740046696C65496E666F0046696C6553797374656D496E666F006765745F4E616D65006765745F457874656E73696F6E006765745F4C656E677468006765745F4C617374577269746554696D65006765745F4372656174696F6E54696D6500546F4461746554696D650046696C65004578697374730047657446696C654E616D65576974686F7574457874656E73696F6E005265706C61636500436F7079004765744C617374577269746554696D65004765744372656174696F6E54696D6500417070656E64416C6C54657874005772697465416C6C54657874000000035C000001000F3C004500520052004F0052003E000007450052005200001531003900300030002D00300031002D003000310001052A002E0000032E00001F500061007400680020006E006F007400200066006F0075006E0064002E00000069F35BF5DADA714CB3CAEB2028898EE90008B77A5C561934E08902060E02060A0306110D060002010E100E070003010E0E100E06000212110E0E070002011C101215130006011C10121510121510111910111D10111D080003010E1002100E080004010E0E0E100E080003010E100A100E090003010E10110D100E03200001042001010E042001010205200101115104200101080520010111611C01000100540E044E616D6510436C725F437265617465466F6C646572042001020E0520010E1D0305000112750E0320000E0907041D0312791D03021C01000100540E044E616D6510436C725F44656C657465466F6C646572040001010E1C01000100540E044E616D6510436C725F52656E616D65466F6C6465720400010E0E0600030E0E0E0E050002010E0E7301000300540E044E616D6511436C725F476574466F6C6465724C697374540E0F5461626C65446566696E6974696F6E1646696C654E616D65206E766172636861722832353529540E1146696C6C526F774D6574686F644E616D6518436C725F476574466F6C6465724C69737446696C6C526F770600021D0E0E0E042001081C14070A1D0E1280851D030E127912111D03021D0E080400010E1C06000111808D0E0620010111808D0307010E80E201000300540E044E616D6519436C725F476574466F6C6465724C69737444657461696C6564540E0F5461626C65446566696E6974696F6E7546696C654E616D65206E7661726368617228323535292C2046696C65457874656E73696F6E206E7661726368617228323535292C2046696C6553697A654279746520626967696E742C204D6F64696669656444617465206461746574696D652C204372656174656444617465206461746574696D65540E1146696C6C526F774D6574686F644E616D6520436C725F476574466F6C6465724C69737444657461696C656446696C6C526F770320000A042000110D050001110D0E19070C1D0E12808511081280911D030E127912111D03021D0E08042001010A05200101110D04070111081A01000100540E044E616D650E436C725F46696C65457869737473040001020E04070112791A01000100540E044E616D650E436C725F44656C65746546696C651B01000100540E044E616D650F436C725F44656C65746546696C65730F07081D0E1D030E12791D03021D0E082401000100540E044E616D6518436C725F4368616E676546696C65457874656E73696F6E730500020E0E0E0500010E1D0E1107091D0E1D030E12791D03021D0E081D0E1A01000100540E044E616D650E436C725F52656E616D6546696C650520020E0E0E1801000100540E044E616D650C436C725F436F707946696C650807031D0312791D031801000100540E044E616D650C436C725F4D6F766546696C651901000100540E044E616D650D436C725F4D6F766546696C65731F01000100540E044E616D6513436C725F47657446696C6553697A654279746507070212809112792301000100540E044E616D6517436C725F47657446696C65446174654D6F6469666965640507021279022201000100540E044E616D6516436C725F47657446696C6544617465437265617465642201000100540E044E616D6516436C725F417070656E64537472696E67546F46696C652101000100540E044E616D6515436C725F5772697465537472696E67546F46696C6519010014596F757253716C4462615F436C7246696C654F7000000501000000000E0100094D6963726F736F667400002401001F436F7079726967687420C2A920536F6369657465204752494353203230313100000801000701000000000801000800000000001E01000100540216577261704E6F6E457863657074696F6E5468726F777301000000000894D55200000000020000001C010000B43D0000B41F0000525344535294223278304D449CFDBA5847D2D19101000000633A5C45717569706553716C5C596F757253716C4462615C596F757253716C4462615F436C7246696C654F705C6F626A5C44656275675C596F757253716C4462615F436C7246696C654F702E70646200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000F83E000000000000000000000E3F0000002000000000000000000000000000000000000000000000003F00000000000000005F436F72446C6C4D61696E006D73636F7265652E646C6C0000000000FF25002000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100100000001800008000000000000000000000000000000100010000003000008000000000000000000000000000000100000000004800000058400000900300000000000000000000900334000000560053005F00560045005200530049004F004E005F0049004E0046004F0000000000BD04EFFE0000010000000100DC67071400000100DC6707143F000000000000000400000002000000000000000000000000000000440000000100560061007200460069006C00650049006E0066006F00000000002400040000005400720061006E0073006C006100740069006F006E00000000000000B004F0020000010053007400720069006E006700460069006C00650049006E0066006F000000CC020000010030003000300030003000340062003000000034000A00010043006F006D00700061006E0079004E0061006D006500000000004D006900630072006F0073006F00660074000000540015000100460069006C0065004400650073006300720069007000740069006F006E000000000059006F0075007200530071006C004400620061005F0043006C007200460069006C0065004F0070000000000040000F000100460069006C006500560065007200730069006F006E000000000031002E0030002E0035003100320037002E00320036003500380038000000000054001900010049006E007400650072006E0061006C004E0061006D006500000059006F0075007200530071006C004400620061005F0043006C007200460069006C0065004F0070002E0064006C006C000000000064001F0001004C006500670061006C0043006F007000790072006900670068007400000043006F0070007900720069006700680074002000A900200053006F006300690065007400650020004700520049004300530020003200300031003100000000005C00190001004F0072006900670069006E0061006C00460069006C0065006E0061006D006500000059006F0075007200530071006C004400620061005F0043006C007200460069006C0065004F0070002E0064006C006C00000000004C0015000100500072006F0064007500630074004E0061006D0065000000000059006F0075007200530071006C004400620061005F0043006C007200460069006C0065004F0070000000000044000F000100500072006F006400750063007400560065007200730069006F006E00000031002E0030002E0035003100320037002E00320036003500380038000000000048000F00010041007300730065006D0062006C0079002000560065007200730069006F006E00000031002E0030002E0035003100320037002E003200360035003800380000000000000000000000000000000000000000000000000000000000003000000C000000203F00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
WITH PERMISSION_SET = EXTERNAL_ACCESS
GO
CREATE PROC yUtl.clr_CreateFolder (@FolderPath nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_CreateFolder];
GO
CREATE PROC yUtl.clr_DeleteFolder (@FolderPath nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_DeleteFolder];
GO
CREATE PROC yUtl.clr_RenameFolder (@FolderPath nvarchar(4000), @NewFolderName nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_RenameFolder];
GO
CREATE FUNCTION yUtl.clr_GetFolderList (@FolderPath nvarchar(4000), @SearchPattern nvarchar(4000)) 
RETURNS TABLE ([FileName] nvarchar(255))
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_GetFolderList];
GO
CREATE FUNCTION yUtl.clr_GetFolderListDetailed (@FolderPath nvarchar(4000), @SearchPattern nvarchar(4000)) 
RETURNS TABLE ([FileName] nvarchar(255), [FileExtension] nvarchar(255), [Size] bigint, [ModifiedDate] datetime, [CreatedDate] datetime)
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_GetFolderListDetailed];
GO
CREATE PROC yUtl.clr_FileExists (@FilePath nvarchar(4000), @FileExistsFlag bit OUTPUT, @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_FileExists];
GO
CREATE PROC yUtl.clr_DeleteFile (@FolderPath nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_DeleteFile];
GO
CREATE PROC yUtl.clr_DeleteFiles (@FolderPath nvarchar(4000), @SearchPattern nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_DeleteFiles];
GO
CREATE PROC yUtl.clr_ChangeFileExtensions (@FolderPath nvarchar(4000), @OldExtension nvarchar(4000), @NewExtension nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_ChangeFileExtensions];
GO
CREATE PROC yUtl.clr_RenameFile (@FilePath nvarchar(4000), @NewFileName nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_RenameFile];
GO
CREATE PROC yUtl.clr_CopyFile (@SourceFilePath nvarchar(4000), @DestinationFilePath nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_CopyFile];
GO
CREATE PROC yUtl.clr_MoveFile (@SourceFilePath nvarchar(4000), @DestinationFolderPath nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_MoveFile];
GO
CREATE PROC yUtl.clr_MoveFiles (@FolderPath nvarchar(4000), @SearchPattern nvarchar(4000), @DestinationFolderPath nvarchar(4000), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_MoveFiles];
GO
CREATE PROC yUtl.clr_GetFileSizeByte (@FilePath nvarchar(4000), @FileSizeByte bigint OUTPUT, @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_GetFileSizeByte];
GO
CREATE PROC yUtl.clr_GetFileDateModified (@FilePath nvarchar(4000), @ModifiedDate datetime OUTPUT, @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_GetFileDateModified];
GO
CREATE PROC yUtl.clr_GetFileDateCreated (@FilePath nvarchar(4000), @CreatedDate datetime OUTPUT, @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_GetFileDateCreated];
go
CREATE PROC yUtl.clr_AppendStringToFile (@FilePath nvarchar(4000), @FileContents nvarchar(MAX), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_AppendStringToFile];
GO
CREATE PROC yUtl.clr_WriteStringToFile (@FilePath nvarchar(4000), @FileContents nvarchar(MAX), @ErrorMessage nvarchar(4000) OUTPUT) 
AS EXTERNAL NAME [YourSqlDba_ClrFileOp].[Clr_FileOperations.FileOpCs].[Clr_WriteStringToFile];
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yInstall.SqlVersionNumber'
go
Create Function yInstall.SqlVersionNumber ()
Returns Int
as
Begin
  Declare @i int;
  With VersionBrute (ver) as (Select convert(nvarchar, serverproperty('ProductVersion')))
  Select @i = convert (int, Left(ver, charindex('.', ver)-1)) From VersionBrute 
  return @i*10 -- match compatibility level
End
go
-- this procedure reports bestPractices to follow
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'PerfMon.GetBestPracticesMsgs'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Create Function PerfMon.GetBestPracticesMsgs ()
returns Table
as
Return
(
With 
  MemSqlmax (MemIngb) as 
  (
  Select top 1 -- for some reason this top 1 clause makes the optimizer choose an access plan that works fine with the loop below. (found at sql2012 sp3)
    Convert(int, Round((total_physical_memory_kb/(1024.0)) / 1024.0, 0))
  From sys.dm_os_sys_memory 
  )
  -- rows builder for a loop
, L0 AS (select 1 as c union all Select 1 as c ) --2
, L1 as (select 1 as C From L0 as A Cross JOIN L0 as B ) --4
, L2 as (select 1 as C From L1 as A Cross JOIN L1 as B ) -- 16
, L3 as (select 1 as C From L2 as A Cross JOIN L2 as B ) -- 256
, L4 as (select 1 as C From L3 as A Cross JOIN L3 as B ) -- 65536
  -- row_number() limits the number of row built
, nums as (Select ROW_NUMBER() OVER (Order by c) as i from L4) 
  -- condition goes over previous row_number() indirectly which limits it
, Loop as (Select * From MemSqlMax Join Nums ON i <= MemInGb)
, FreeSpaceByGb as
  (
  Select 
    memInGb
  , Loop.i
  , Case 
      When Loop.i <= 4 then 0 -- below 4Gb, there is already 1Gb that will be added later
      When Loop.i > 4.1 and Loop.i <= 16 Then 0.25 -- between 4Gb et 16Gb  add 0.25Gb of free space by Gb for the OS
      When Loop.i > 16.1 Then 0.125 -- Above 16gb  add 0.125 Gb of free space by Gb for the OS
    End as FreeMem 
  From Loop
  )
  --Select * from FreeSpaceByGb Order by i
, TbMinFreeSpaceInMb as 
  (
  Select MemInGb, 1+SUM(FreeMem) as ToFree, Convert(Int, ((MemInGb - (1+SUM(FreeMem))) * 1024)) as MaxSpaceToUseInMb
  From FreeSpaceByGb
  Group By MemInGb
  )
  --Select * from TbMinFreeSpaceInMb
, optionVal (opt, val) as
  (
  Select 'Max server memory (MB)', convert(int, MaxSpaceToUseInMb) 
  From sys.configurations CROSS JOIN TbMinFreeSpaceInMb
  Where name = 'max server memory (MB)' And (value_in_use = 0 Or value_in_use > CONVERT(Int, MaxSpaceToUseInMb))
  UNION ALL
  Select 'max degree of parallelism', 3
  From sys.configurations 
  Where name = 'max degree of parallelism' And value = 0
  UNION ALL
  Select 'cost threshold for parallelism', 50
  From 
    sys.configurations C1
    JOIN sys.configurations C2 ON C2.name = 'max degree of parallelism' And C2.Value <> 1
    JOIN sys.dm_os_sys_info DMOS ON DMOS.cpu_count > 1 And DMOS.affinity_type_desc = 'AUTO'
  Where C1.name = 'cost threshold for parallelism' And C1.value < 50
  UNION ALL
  Select 'backup compression default', 1
  From sys.configurations 
  Where name = 'backup compression default' And value <> 1
  UNION ALL
  Select 'nested triggers', 1
  From sys.configurations 
  Where name = 'nested triggers' And value <> 1
  )
Select 
  Case 
    When @@LANGUAGE <> 'français' 
    Then 'Adjust following server settings by executing following commands:'
    Else 'Ajuster les propriétés suivantes du serveur en exécutant les commandes suivantes'
  End + '<br>' + r3.s +  '<Br>Reconfigure<Br>GO<Br>'
  as MsgLines
From 
  ( Select (Select CONVERT(nvarchar(max), '<br>exec Sp_Configure '''+opt+''', '+convert(nvarchar, val) + '<Br>GO') From optionVal for Xml path('')) as Msgs ) as r0 
  CROSS APPLY (Select REPLACE (r0.Msgs, '&gt;', '>') ) as r1(s)
  CROSS APPLY (Select REPLACE (r1.s, '&Lt;', '<') ) as r2(s)
  CROSS APPLY (Select REPLACE (r2.s, '&#x0D;', '<Br>')) as r3(s)
)
GO
Exec f$.DropObj 'PerfMon.ReportIgnoredBestPractices'
GO
Create Proc PerfMon.ReportIgnoredBestPractices @email_Address sysname
As
Begin
  Declare @Msg Nvarchar(max)
  Select @Msg = GM.MsgLines From PerfMon.GetBestPracticesMsgs() GM

  If @Msg IS NOT NULL
    EXEC  Msdb.dbo.sp_send_dbmail
      @profile_name = 'YourSQLDba_EmailProfile'
    , @recipients = @email_Address
    , @importance = 'High'
    , @subject = 'YourSqlDba : Apply following good practices to your SQL Server configuration'
    , @body = @Msg
    , @body_format = 'HTML'

-- Exec PerfMon.ReportIgnoredBestPractices 'pelchatm@grics.ca'
End
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.QryReplace'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create procedure yExecNLog.QryReplace -- do multiple replace on dynamic SQL generation
  @sql nvarchar(max) Output
, @srch1 nvarchar(1000) 
, @by1 nvarchar(1000)
, @srch2 nvarchar(1000) = ''
, @by2 nvarchar(1000) = ''
, @srch3 nvarchar(1000) = ''
, @by3 nvarchar(1000) = ''
, @srch4 nvarchar(1000) = ''
, @by4 nvarchar(1000) = ''
, @srch5 nvarchar(1000) = ''
, @by5 nvarchar(1000) = ''
, @srch6 nvarchar(1000) = ''
, @by6 nvarchar(1000) = ''
as
Begin
  set @sql = replace (@sql, @srch1, @by1)
  If isnull(@srch2,'') <> '' Set @sql = replace (@sql, @srch2, @by2)
  If isnull(@srch3,'') <> '' Set @sql = replace (@sql, @srch3, @by3)
  If isnull(@srch4,'') <> '' Set @sql = replace (@sql, @srch4, @by4)
  If isnull(@srch5,'') <> '' Set @sql = replace (@sql, @srch5, @by5)
  If isnull(@srch6,'') <> '' Set @sql = replace (@sql, @srch6, @by6)
End -- yExecNLog.QryReplace
GO
Exec f$.DropObj 'yUtl.ColumnInfo'
go
Create function yUtl.ColumnInfo (@tbName sysname, @colName sysname, @typeName sysname = NULL)
returns table
as
  return
  (
  Select
    OBJECT_SCHEMA_NAME (c.object_id) as schName, object_name(object_id) as TbName, TYPE_NAME (c.user_type_id) as TypeName, c.*
  From 
    Sys.columns C
  Where c.object_id = object_id(@tbName)
    And c.name = @colName
    And (@typeName is NULL Or @typeName = TYPE_NAME (c.user_type_id) )
  )  
GO -- yUtl.ColumnInfo

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.FormatBasicBeginCatchErrMsg'
GO
create function yExecNLog.FormatBasicBeginCatchErrMsg ()
returns nvarchar(max) 
as
Begin
  Return
  (
    'err :' 
  + convert(nvarchar(10), error_number()) + ' ' 
  + ERROR_MESSAGE () + ' ' 
  + case when error_procedure() is not null Then ' In procedure ' + error_procedure() + ':' End
  + case when error_line() is not null Then ' at line ' + CONVERT(nvarchar, ERROR_LINE()) End
  )

End
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.Unindent_TSQL' -- newer shema
GO
-- ------------------------------------------------------------------------------
-- This function unindent TSQL code so that the leftmost code is in column one
-- It helps log log dynamic T-SQL that is originally generated indented relative 
-- to it the code where it is defined.  It is to ease nice dynamic code formatting
-- at code level, and avoid extra indentation of gnererated code in logs
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create function yExecNLog.Unindent_TSQL
(
  @sql nvarchar(max)
)
returns nvarchar(max)
as
Begin
  Declare @NbOfLn Int
  Declare @NextSql nvarchar(max)
  
  -- Unindent T-SQL to have leftmost code to start in column on
  Set @NbOfLn = len(@sql) - len(replace(@sql, nchar(10)+' ', nchar(10)+''))
  
  If @NbOfLn = 0 Return (@sql) -- otherwise endless loop (happen with empty @sql string or @sql string without CRLF
  
  While (1 = 1)
  Begin
    set @NextSql = replace (@sql, nchar(10)+' ', nchar(10)+'')        
    If len(@sql) - len(@NextSql) = @NbOfLn
      Set @sql = @NextSql
    Else 
      Break  
  End  -- while

  Return (@sql)
End -- yExecNLog.Unindent_TSQL
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.ReplaceByXmlEscapeChar'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
-- this function purpose is to replace all chars 
-- that needs to be escpaed in XML before converting old table content
Create Function yExecNLog.ReplaceByXmlEscapeChar (@txt varchar(max))
returns nvarchar(max)
as
Begin
  With t0 (t) as (select @txt)
  , t1 (t) as (select REPLACE(t, '&', '&amp;') from t0) 
  , t2 (t) as (select REPLACE(t, '<', '&lt;') from t1) 
  , t3 (t) as (select REPLACE(t, '>', '&gt;') from t2) 
  Select @txt = t from t3
  Return (@txt)
End  
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.CommandText'
GO
create proc yExecNLog.CommandText 
  @CommandText nvarchar(max) = '' output
as
Begin
  If object_id('tempdb..#DBCCinputBuffer') is not null 
    Exec ('Drop TABLE #DBCCinputBuffer')

  CREATE TABLE #DBCCinputBuffer(
  EventType NVARCHAR(30) NULL,
  Parameters INT NULL,
  EventInfo NVARCHAR(4000) NULL
  )

  INSERT #DBCCinputBuffer
  EXEC('DBCC INPUTBUFFER(@@SPID) WITH NO_INFOMSGS ')  

  --DECLARE @tBuff nvarchar(4000)	
  SET @CommandText = ''		

  SET @CommandText = (SELECT TOP 1 EventInfo FROM #DBCCinputBuffer)
  
  DROP TABLE #DBCCinputBuffer
  
End -- yExecNLog.CommandText
GO

-- ------------------------------------------------------------------------------
-- Function to get the command executed outside of SQL Server Agent
-- and present it in Html
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.CommandTextIntoHtml'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc yExecNLog.CommandTextIntoHtml 
  @CommandTextInHtml nvarchar(max) = 'B' output
as
Begin
  Declare @crLf nvarchar(4) Set @crlf = yUtl.UnicodeCrLf()
  Declare @CommandText nvarchar(max) Set @CommandText = 'A'

--print '@CommandText1="' + isnull(@CommandText,'') + '"'
  exec YourSqlDba.yExecNLog.CommandText @CommandText = @CommandText output
--print '@CommandText2="' + isnull(@CommandText,'') + '"'

  -- replace spaces by "html spaces"
  Set @CommandText = replace (@CommandText, ' ', '&nbsp;')

  -- normalize use of crlf 
  Set @CommandText = replace (@CommandText, @crLf, '<br>')
  Set @CommandText = replace (@CommandText, '<br>', '<br>' + @crLf)

  Set @CommandText = replace(@CommandText, '"', '''')

  Set @CommandTextInHtml =
  '
  <br>
  <font size="3"><b>Command executed</b></font><br>
  <br>
  <table width="100%" border=1 cellspacing=0 cellpadding=5 style="background:#CCCCCC;border-collapse:collapse;border:none">
    <tr>
      <td width="100%" valign=top style="border:solid windowtext 1.0pt">
        <font face="Courier New" size="2">
        <span style="color:navy">
        <@CommandText>
        </span></font>
      </td>
    </tr>
  </table>
  '

  Set @CommandTextInHtml = replace(@CommandTextInHtml, '<@CommandText>', @CommandText)
  Set @CommandTextInHtml = replace(@CommandTextInHtml, '"', '''')

End -- yExecNLog.Utl.CommandTextIntoHtml
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yInstall.DoubleLastSpaceInFirst78Colums'
GO
create function yInstall.DoubleLastSpaceInFirst78Colums 
(
  @msg nvarchar(max)
)
returns nvarchar(max)
as
Begin
  If len(@msg) > 78
    -- Note that a bug exist in sp_send_dbmail.
    -- The @subject parameter is wrap from the 78 th column.
    -- Then the previous space is replaced by a line feed which is then ignore by sp_send_dbmail.
    -- A solution is to replace the last space in the first 78 columns of the "@msg" variable
    -- by two spaces.
  Begin
    Declare @First78 nvarchar(max)
    Declare @reverse78 nvarchar(max)
    Declare @spacePos int
    Set @First78 = left(@msg, 78)
    Set @reverse78 = REVERSE(@First78)
    Set @spacePos = PATINDEX('% %', @reverse78)    -- position of the first space
    Set @spacePos = 79 - @spacePos               -- position of the last space in the first 78 characters
    Set @msg = STUFF(@msg, @spacePos, 1, '  ')   -- Replace the space by 2 spaces 
  End

  Return @msg
End -- yInstall.DoubleLastSpaceInFirst78Colums
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yInstall.DoubleLastSpaceInFirst150Colums'
GO
create function yInstall.DoubleLastSpaceInFirst150Colums 
(
  @msg nvarchar(max)
)
returns nvarchar(max)
as
Begin
  If len(@msg) > 150
    -- Note that a bug exist in sp_send_dbmail.
    -- The @subject parameter is wrap from the 78 th column and the 150 th.
    -- Then the previous space is replaced by a line feed which is then ignore by sp_send_dbmail.
    -- A solution is to replace the last space in the first 78 colomns of the "@msg" variable
    -- by two spaces.  And also the 150 th column.
  Begin
    Declare @First150 nvarchar(max)
    Declare @reverse150 nvarchar(max)
    Declare @spacePos int
    Set @First150 = left(@msg, 150)
    Set @reverse150 = REVERSE(@First150)
    Set @spacePos = PATINDEX('% %', @reverse150)   -- position of the first space
    Set @spacePos = 151 - @spacePos                -- position of the last space in the first 150 characters
    Set @msg = STUFF(@msg, @spacePos, 1, '  ')     -- Replace the space by 2 spaces 
  End

  Return @msg
End -- yInstall.DoubleLastSpaceInFirst150Colums
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'PerfMon.LockChainView'
GO
CREATE view PerfMon.LockChainView
as
With LockChainCTE
as
(
select 
  A.program_name as BlockingApp
, A.hostname as BlockingHost
, A.cmd as BlockingCmd
, A.spid as BlockindSpid
, DB_NAME(A.dbid) as BlockingDbSite
, A.blocked as BlockedSPid
from 
  master.sys.sysprocesses As A
where A.spid >= 51 And A.blocked > 0

UNION ALL

Select 
  B.program_name 
, B.hostname 
, B.cmd 
, b.spid 
, DB_NAME(B.dbid) 
, B.blocked 
From 
  LockChainCTE as A
  join
  master.sys.sysprocesses as B
  ON B.spid = A.BlockindSpid
) 
select 
  A.*
, B.program_name as BlockedApp
, B.hostname as BlockedHost
, B.cmd as BlockedCmd
, DB_NAME(b.dbid) as BlockedDbSite
from 
  LockChainCte A
  join
  master.sys.sysprocesses as B
  On  B.spid = A.BlockedSPid 

-- End of view PerfMon.LockChainView
GO
------------------------------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'PerfMon.ResetAnalyzeWaitStats'
GO
-- This procedure is derived from code obtained from Paul Randal blog's site
Create Procedure PerfMon.ResetAnalyzeWaitStats 
as DBCC SQLPERF ('sys.dm_os_wait_stats', CLEAR); 
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'PerfMon.AnalyzeWaitStats'
GO
-- This function is derived from code obtained from Paul Randal blog's site
Create Function PerfMon.AnalyzeWaitStats () 
returns table
as
return
(
  -- reset wait stats with this : DBCC SQLPERF ('sys.dm_os_wait_stats', CLEAR); 
  with 
    unwanted_wait_types (wait_type)
    as
    (
    --select 
    --'select '''+wait_type+''' union all ' 
    --from sys.dm_os_wait_stats order by wait_type 
    select 'BROKER_EVENTHANDLER' union all 
    select 'BROKER_RECEIVE_WAITFOR' union all 
    select 'BROKER_TASK_STOP' union all 
    select 'BROKER_TO_FLUSH' union all 
    select 'BROKER_TRANSMITTER' union all 
    select 'CHECKPOINT_QUEUE' union all 
    select 'CHKPT' union all 
    select 'CLR_AUTO_EVENT' union all 
    select 'CLR_MANUAL_EVENT' union all 
    select 'CLR_SEMAPHORE' union all 
    select 'DBMIRROR_DBM_MUTEX' union all
    select 'DBMIRROR_EVENTS_QUEUE' union all
    select 'DBMIRRORING_CMD' union all
    select 'DIRTY_PAGE_POLL' union all -- sql2012
    select 'DISPATCHER_QUEUE_SEMAPHORE' union all 
    select 'FFT_RECOVERY' union all 
    select 'FT_IFTS_SCHEDULER_IDLE_WAIT' union all 
    select 'FT_IFTSHC_MUTEX' union all 
    select 'HADR_FILESTREAM_IOMGR_IOCOMPLETION' union all 
    select 'LOGMGR_QUEUE' union all 
    select 'LAZYWRITER_SLEEP' union all
    select 'ONDEMAND_TASK_QUEUE' union all 
    select 'PWAIT_ALL_COMPONENTS_INITIALIZED' union all 
    Select 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP' union all
    Select 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP' union all
    --Select 'QDS_ASYNC_QUEUE' union all
    select 'REQUEST_FOR_DEADLOCK_SEARCH' union all 
    select 'RESOURCE_QUEUE' union all 
    select 'SERVER_IDLE_CHECK' union all 
    select 'SLEEP' union all 
    select 'SLEEP_BPOOL_FLUSH' union all 
    select 'SLEEP_DBSTARTUP' union all 
    select 'SLEEP_DCOMSTARTUP' union all 
    select 'SLEEP_MASTERDBREADY' union all 
    select 'SLEEP_MSDBSTARTUP' union all 
    select 'SLEEP_SYSTEMTASK' union all 
    select 'SLEEP_TASK' union all 
    select 'SLEEP_TEMPDBSTARTUP' union all 
    select 'SNI_HTTP_ACCEPT' union all 
    select 'SP_SERVER_DIAGNOSTICS_SLEEP' union all
    select 'SQLTRACE_FILE_BUFFER_FLUSH' union all 
    select 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP' union all 
    select 'Total' union all 
    select 'TRACEWRITE' union all 
    select 'WAITFOR' union all 
    select 'WAITFOR_TASKSHUTDOWN' union all 
    select 'XE_DISPATCHER_JOIN' union all 
    select 'XE_DISPATCHER_WAIT' union all 
    select 'XE_TIMER_EVENT' union all 
    select '' where 1=2
    )
  , Waits_Sum_Wait_time_ms AS
    (
    SELECT
      wait_type,
      signal_wait_time_ms, 
      wait_time_ms / 1000.0 AS WaitS,
      (wait_time_ms - signal_wait_time_ms) / 1000.0 AS ResourceS,
      signal_wait_time_ms / 1000.0 AS SignalS,
      waiting_tasks_count AS WaitCount,
      wait_time_ms, 
      Sum(wait_time_ms) OVER() AS TotalTimeMs,
      ROW_NUMBER() OVER(ORDER BY wait_time_ms DESC) AS RowNum
    FROM sys.dm_os_wait_stats
    WHERE 
        wait_type NOT IN (Select wait_type from unwanted_wait_types)
    And wait_type not like 'PREEMPTIVE[_]%'
    )
  , Waits AS
    (
    SELECT
      wait_type,
      wait_time_ms / 1000.0 AS WaitS,
      (wait_time_ms - signal_wait_time_ms) / 1000.0 AS ResourceS,
      signal_wait_time_ms / 1000.0 AS SignalS,
      Waitcount,
      100.0 * wait_time_ms / (case when TotalTimeMs > 0.0 Then TotalTimeMs Else 1 End) AS Percentage,
      RowNum
    FROM Waits_Sum_Wait_time_ms
    Where WaitCount > 0
  )
  SELECT
      W1.wait_type AS WaitType, 
      CAST (W1.WaitS AS DECIMAL(14, 2)) AS Wait_S,
      CAST (W1.ResourceS AS DECIMAL(14, 2)) AS Resource_S,
      CAST (W1.SignalS AS DECIMAL(14, 2)) AS Signal_S,
      W1.WaitCount AS WaitCount,
      CAST (W1.Percentage AS DECIMAL(5, 2)) AS Percentage,
      CAST ((W1.WaitS / W1.WaitCount) AS DECIMAL (14, 4)) AS AvgWait_S,
      CAST ((W1.ResourceS / W1.WaitCount) AS DECIMAL (14, 4)) AS AvgRes_S,
      CAST ((W1.SignalS / W1.WaitCount) AS DECIMAL (14, 4)) AS AvgSig_S
  FROM Waits AS W1
      INNER JOIN Waits AS W2 ON W2.RowNum <= W1.RowNum
  GROUP BY W1.RowNum, W1.wait_type, W1.WaitS, W1.ResourceS, W1.SignalS, W1.WaitCount, W1.Percentage
  HAVING SUM (W2.Percentage) - W1.Percentage < 95 -- percentage threshold
)
go
exec f$.DropObj 'yPerfMon.ActiveQueryInBatch'
go
create function yPerfMon.ActiveQueryInBatch(@batch nvarchar(max), @start int, @end int) 
returns table
return
(
With CalcStartEnd as (Select (@start/2)+1 as start, (CASE @end When -1 Then DATALENGTH(@batch) Else @End End)/2+1 as Stringlen)
Select SUBSTRING (@batch, start, Stringlen) as RunningQuery
from CalcStartEnd 
);
go
exec f$.DropObj 'perfmon.SessionInfo'
go
create view perfmon.SessionInfo
as
select 
  q.RunningQuery
, T.Text as QueryBatch
, db_name(r.database_id) as dbName
, r.blocking_session_id as BlockedBy
, S.host_name
, S.program_name
, S.status
, S.cpu_time
, S.memory_usage
, S.row_count
, S.total_scheduled_time
, S.total_elapsed_time
, S.reads
, S.writes
, S.logical_reads
, r.start_time
, r.percent_complete
, s.last_request_start_time
, S.last_request_end_time
, S.login_name
, S.client_interface_name
, S.client_version
, S.nt_domain
, S.nt_user_name
, S.context_info
, S.endpoint_id
, S.is_user_process
, S.language
, S.date_format
, S.date_first
, S.quoted_identifier
, S.arithabort
, S.ansi_null_dflt_on
, S.ansi_defaults
, S.ansi_warnings
, S.ansi_padding
, S.ansi_nulls
, S.concat_null_yields_null
, S.transaction_isolation_level
, S.lock_timeout
, S.deadlock_priority
, S.prev_error
, S.original_security_id
, S.original_login_name
, S.last_successful_logon
, S.last_unsuccessful_logon
, S.unsuccessful_logons
, S.login_time
, S.host_process_id
, C.protocol_version 
, C.net_transport 
, p.query_plan 
from 
  sys.dm_exec_sessions S
  left join
  sys.dm_exec_connections C
  On C.session_id = S.session_id  
  left join
  sys.dm_exec_requests R
  on R.session_id = S.session_id 
  outer apply
  sys.dm_exec_sql_text (r.sql_handle) as T
  outer apply
  yPerfMon.ActiveQueryInBatch(T.Text, r.statement_start_offset, r.statement_end_offset) as q
  outer apply 
  sys.dm_exec_query_plan(r.plan_handle) p

where s.program_name is not null
go

exec f$.DropObj 'PerfMon.DetailQueriesStats'
go
Create Function PerfMon.DetailQueriesStats()
Returns Table
as
Return
(
With 
  QueryStats as
  (
  SELECT 
    P.type_desc
  , DB_NAME(database_id) as DbName
  , object_name(object_id, database_id) as ObjName
  , CONVERT(nvarchar(max), '') as RunningQryInBatch
  , T.query_plan
  , cached_time
  , last_execution_time
  , execution_count
  , total_worker_time
  , last_worker_time
  , min_worker_time
  , max_worker_time
  , total_physical_reads
  , last_physical_reads
  , min_physical_reads
  , max_physical_reads
  , total_logical_writes
  , last_logical_writes
  , min_logical_writes
  , max_logical_writes
  , total_logical_reads
  , last_logical_reads
  , min_logical_reads
  , max_logical_reads
  , total_elapsed_time
  , last_elapsed_time
  , min_elapsed_time
  , max_elapsed_time
  FROM 
    master.sys.dm_exec_procedure_stats as P
    cross apply sys.dm_exec_query_plan(plan_handle)  as T

  UNION ALL
  SELECT 
    P.type_desc
  , DB_NAME(database_id)
  , object_name(object_id, database_id)
  , CONVERT(nvarchar(max), '') as RunningQryInBatch
  , T.query_plan
  , cached_time
  , last_execution_time
  , execution_count
  , total_worker_time
  , last_worker_time
  , min_worker_time
  , max_worker_time
  , total_physical_reads
  , last_physical_reads
  , min_physical_reads
  , max_physical_reads
  , total_logical_writes
  , last_logical_writes
  , min_logical_writes
  , max_logical_writes
  , total_logical_reads
  , last_logical_reads
  , min_logical_reads
  , max_logical_reads
  , total_elapsed_time
  , last_elapsed_time
  , min_elapsed_time
  , max_elapsed_time
  FROM 
    master.sys.dm_exec_Trigger_stats as P
    cross apply sys.dm_exec_query_plan(plan_handle)  as T

  UNION ALL
  SELECT 
    P.type_desc
  , DB_NAME(database_id)
  , object_name(object_id, database_id)
  , CONVERT(nvarchar(max), '') as RunningQryInBatch
  , T.query_plan
  , cached_time
  , last_execution_time
  , execution_count
  , total_worker_time
  , last_worker_time
  , min_worker_time
  , max_worker_time
  , total_physical_reads
  , last_physical_reads
  , min_physical_reads
  , max_physical_reads
  , total_logical_writes
  , last_logical_writes
  , min_logical_writes
  , max_logical_writes
  , total_logical_reads
  , last_logical_reads
  , min_logical_reads
  , max_logical_reads
  , total_elapsed_time
  , last_elapsed_time
  , min_elapsed_time
  , max_elapsed_time
  FROM 
    master.sys.dm_exec_Function_stats as P
    cross apply sys.dm_exec_query_plan(plan_handle)  as T

  UNION ALL
  SELECT 
    'Query'
  , ''
  , ''
  , RunningQryInBatch
  , query_plan
  , NULL
  , last_execution_time
  , execution_count
  , total_worker_time
  , last_worker_time
  , min_worker_time
  , max_worker_time
  , total_physical_reads
  , last_physical_reads
  , min_physical_reads
  , max_physical_reads
  , total_logical_writes
  , last_logical_writes
  , min_logical_writes
  , max_logical_writes
  , total_logical_reads
  , last_logical_reads
  , min_logical_reads
  , max_logical_reads
  , total_elapsed_time
  , last_elapsed_time
  , min_elapsed_time
  , max_elapsed_time
  FROM 
    master.sys.dm_exec_query_stats as Q
    cross apply sys.dm_exec_query_plan(Q.plan_handle)  as P
    cross apply sys.dm_exec_sql_text(Q.Sql_handle)  as T
    cross apply (Select StartOfQryInBatch = 1+(Q.statement_start_offset/2)) as vStartOfQryInBatch
    cross apply (Select BatchLen = DATALENGTH(T.text)) as vBatchLen
    cross apply (Select QryStrLen = 1+(Case When Q.statement_end_offset=-1 Then BatchLen Else Q.statement_end_offset End)/2) as vQueryLen
    Cross Apply (Select RunningQryInBatch = Substring(T.text, StartOfQryInBatch, QryStrLen)) as vRunningQryInBatch
  )
Select *
From 
  QueryStats
Where 
  total_logical_reads/execution_count > 100 
)
GO
-- ------------------------------------------------------------------------------
-- Création des tables d'historique
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO


-- under construction
If object_id('Maint.DbMaintPolicies') is not null 
   And Not Exists (select * from yUtl.ColumnInfo ('Maint.DbMaintPolicies', 'FullBkExt', NULL))
   Drop Table Maint.DbMaintPolicies
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO

Exec f$.DropObj 'Maint.XpCmdShellSavedState'
go
CREATE TABLE Maint.XpCmdShellSavedState
(
  EnforceSingleRowTable int default 1 primary key
, value_In_Use int 
) 
go

-- if the table doesn't exists create the latest version
If object_id('Maint.JobHistory') is null 
Begin
  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table  Maint.JobHistory
  (
    JobNo                                         int identity(1,1) 
  , DoInteg                                       Bit default 0 
  , DoUpdStats                                    Bit default 0 
  , DoReorg                                       Bit default 0 
  , DoFullBkp                                     Bit default 0 
  , DoDiffBkp                                     Bit default 0 
  , DoLogBkp                                      Bit default 0 
  , JobName                                       nvarchar(128) default "" NULL
  , JobStart                                      datetime default getdate()
  , JobEnd                                        datetime default getdate()
  , IncDb                                         nvarchar(max) NULL
  , ExcDb                                         nvarchar(max) NULL
  , ExcDbFromPolicy_CheckFullRecoveryModel        nvarchar(max) NULL
  , TimeStampNamingForBackups                     Int NULL
  , FullBkpRetDays                                Int NULL 
  , LogBkpRetDays                                 Int NULL 
  , NotifyMandatoryFullDbBkpBeforeLogBkp          int NULL 
  , SpreadUpdStatRun                              int NULL
  , SpreadCheckDb                                 int NULL
  , FullBackupPath                                nvarchar(512) NULL 
  , LogBackupPath                                 nvarchar(512) NULL 
  , FullBkExt                                     nvarchar(7) NULL default "BAK" -- 7 to allow ext. like BAK.ZIP
  , LogBkExt                                      nvarchar(7) NULL default "TRN" -- 7 to allow ext. like TRN.ZIP
  , ConsecutiveDaysOfFailedBackupsToPutDbOffline  Int NULL 
  , MirrorServer                                  sysname NULL
  , ReplaceSrcBkpPathToMatchingMirrorPath         nvarchar(max) NULL
  , ReplacePathsInDbFilenames                     nvarchar(max) NULL
  , JobId                                         UniqueIdentifier NULL 
  , StepId                                        Int NULL 
  , BkpLogsOnSameFile                             Int NULL default 1
  , spid                                          Int
  , constraint Pk_HistMaintTrav 
    primary key  clustered (JobNo)
  )
  '
  Exec yExecNLog.QryReplace @sql output, '"', ''''
  Exec (@sql)

  If object_id('tempdb..##JobHistory') is not null 
  Begin
    ;With 
      MatchingColsBeforeAndAfter as
      (
      Select 
        (
        Select convert(nvarchar(max), ','+name) as [text()] 
        From YourSqlDba.Sys.Columns Y
        Where object_id=Object_id('YourSqlDba.Maint.JobHistory') 
          And Exists
              (
              Select * 
              FROM tempdb.Sys.Columns Tmp 
              Where object_id=Object_id('TempDb..##JobHistory') And Y.Name = Tmp.Name Collate Database_default
              )
        Order by column_id 
        For xml path('')
        ) as Cols -- comma separated list of matching column name between previous version of the table and this one
      )
    , Template as
      (
      Select 
        '
        Set Identity_insert YourSqlDba.Maint.JobHistory ON
        Delete YourSqlDba.Maint.JobHistory
        Insert into YourSqlDba.Maint.JobHistory («Cols») 
        Select «Cols» From ##JobHistory
        Drop Table ##JobHistory
        Set Identity_insert YourSqlDba.Maint.JobHistory OFF
        ' as Sql
      , Stuff(Cols, 1, 1, '') as Cols -- remove first comma in the cols list 
      From MatchingColsBeforeAndAfter 
      )
    Select 
      @Sql = r0.s
    From 
      Template
      CROSS APPLY (Select REPLACE(Sql, '«Cols»', Cols)) as r0(s)

    Exec (@sql)
  End
End
GO

-- if the table doesn't exists create the latest version
If object_id('Maint.JobSeqUpdStat') is null 
Begin
  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table  Maint.JobSeqUpdStat
  (
    seq         int
  )
  Insert into Maint.JobSeqUpdStat values(0)
  '
  Exec (@sql)

  If Object_Id('tempdb..##JobSeqUpdStat') IS NOT NULL
    Exec
    (
    '
    Insert Into Maint.JobSeqUpdStat (seq) 
    Select Seq
    From ##JobSeqUpdStat
    Drop table ##JobSeqUpdStat
    '
    )
End
GO

-- if the table doesn't exists create the latest version
If object_id('Maint.JobSeqCheckDb') is null 
Begin
  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table  Maint.JobSeqCheckDb
  (
    seq         int
  )
  Insert into Maint.JobSeqCheckDb values(0)
  '
  Exec (@sql)

  If Object_Id('tempdb..##JobSeqCheckDb') IS NOT NULL
    Exec
    (
    '
    Insert Into Maint.JobSeqCheckDb (seq) 
    Select Seq
    From ##JobSeqCheckDb
    Drop table ##JobSeqCheckDb
    '
    )
End
GO

-- if the table doesn't exists create the latest version
If object_id('Maint.JobLastBkpLocations') is null 
Begin
  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table  Maint.JobLastBkpLocations
  (
    dbName                                          Sysname 
  , lastLogBkpFile                                  nvarchar(512) NULL
  , FailedBkpCnt                                    Int Default 0
  , lastFullBkpFile                                 nvarchar(512) NULL
  , lastDiffBkpFile                                 nvarchar(512) NULL
  , keepTrace                                       bit default 0 NOT NULL
  , MirrorServer                                    Sysname NULL
  , lastFullBkpDate                                 Datetime
  , ReplaceSrcBkpPathToMatchingMirrorPath           nvarchar(max) NULL
  , ReplacePathsInDbFilenames                       nvarchar(max) NULL
  , constraint Pk_HistMaintDernBkpPart
    primary key  clustered (dbName)
  )
  '
  Exec (@sql)

  If Object_Id('tempdb..##JobLastBkpLocations') IS NOT NULL
  Begin
    Set @Sql = 
    '
    Insert Into Maint.JobLastBkpLocations 
          (dbName, lastLogBkpFile, lastFullBkpFile, MirrorServer, lastFullBkpDate, ReplaceSrcBkpPathToMatchingMirrorPath, ReplacePathsInDbFilenames)
    Select dbName, lastLogBkpFile, lastFullBkpFile, isnull(S.name,''''), lastFullBkpDate, ReplaceSrcBkpPathToMatchingMirrorPath, ReplacePathsInDbFilenames
    From 
      ##JobLastBkpLocations
      -- cleanup missing mirrorServer if no matching linked server exists
      LEFT JOIN Sys.Servers as S ON S.Name = MirrorServer Collate Database_Default And S.is_linked = 1
    Drop table ##JobLastBkpLocations
    '
    Exec(@Sql)
    --Print @sql
  End 
End
GO

-- if the table doesn't exists create the latest version
If object_id('Maint.JobHistoryAggregateLogBkp') is null 
Begin
  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table  Maint.JobHistoryAggregateLogBkp
  (
    JobId       uniqueIdentifier not null
  , StepId      Int not NULL 
  , JobNo       int
  , constraint Pk_JobHistoryAggregateLogBkp
    primary key  clustered (JobId, StepId)
  )
  '
  Set @Sql = Replace(@Sql, '"', '''')
  Exec (@sql)
End
GO

-- if the table doesn't exists create the latest version
If object_id('Mirroring.TargetServer') is null 
Begin
  Declare @sql nvarchar(max)
  Set @sql =
  '
  create table Mirroring.TargetServer
  (
    MirrorServerName sysname Not Null default ""
  , constraint PK_TargetServer Primary Key (MirrorServerName)
  )
  '
  Set @Sql = Replace(@Sql, '"', '''')
  Exec (@sql)

  If Object_Id('tempdb..##TargetServer') IS NOT NULL
  Begin
    Set @sql =
    '
    Insert Into Mirroring.TargetServer (MirrorServerName)
    Select ISNULL(T.MirrorServerName, "")
    From ##TargetServer T
    Where Exists(Select * From Sys.Servers as S Where S.name = T.MirrorServerName Collate Database_Default And S.is_linked = 1) -- cleanup missing mirrorServer if no matching linked server exists
    Drop table ##TargetServer
    '
    Set @Sql = Replace(@Sql, '"', '''')
    Exec (@sql)
  End
End
GO

-- if the table doesn't exists create latest version
If object_id('Maint.JobHistoryDetails') is NULL
Begin

  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table  Maint.JobHistoryDetails
  (
    JobNo       Int Not NULL
  , seq         Int identity(1,1) 
  , cmdStartTime    datetime default getdate()
  , Secs        Int
  , Action      Xml NULL 
  , ForDiagOnly Bit NULL  
  , constraint  PK_HistMaintSql 
    primary key clustered (JobNo, seq)
  , constraint FK_JobMaintHistoryDetails_TO_JobMaintHistory 
    foreign key (JobNo) references Maint.JobHistory (JobNo) 
    On delete cascade
  )
  '
  Exec yExecNLog.QryReplace @sql output, '"', ''''
  Exec (@sql)
End
go

-- if the table doesn't exists create latest version
If object_id('Maint.TemporaryBackupHeaderInfo') is NULL
Begin

  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table Maint.TemporaryBackupHeaderInfo 
  (
    spid int default @@spid 
  -- columns needed by YourSqlDba
  , BackupType smallint
  , Position smallint
  , DeviceType tinyint
  , DatabaseName nvarchar(128)
  , LastLSN numeric(25,0)
  , constraint PK_TemporaryBackupHeaderInfo primary key (spid, backupType, position, deviceType, DatabaseName)
  )
  '
  Exec (@sql)
End
go

-- if the table doesn't exists create latest version
If object_id('Maint.TemporaryBackupFileListInfo') is NULL
Begin

  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table Maint.TemporaryBackupFileListInfo 
  (
    spid int default @@spid 
  -- columns needed by YourSqlDba
  , LogicalName nvarchar(128) -- Logical name of the file.
  , PhysicalName nvarchar(260) -- Physical or operating-system name of the file.
  , Type NCHAR(1) -- The type of file, one of: L = Microsoft SQL Server log file D = SQL Server data file F = Full Text Catalog 
  , FileID bigint -- File identifier, unique within the database.
  , constraint PK_TemporaryBackupFileListInfo primary key (spid, FileId, Type)
  )
  '
  Exec (@sql)
End
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
declare @sql nvarchar(max)
Set @sql = 
'
Exec f$.DropObj "Install.VersionInfo"
Exec sp_ExecuteSql @SqlCreateFunction
'
Set @sql = REPLACE(@sql, '"', '''')
declare @createFct nvarchar(max)
Set @createFct = 
'
CREATE function Install.VersionInfo ()
returns table 
as
  return
  (
  Select 
    "<version>" As VersionNumber
  , "<VerDate>" as VersionDate
  , "<UpdateReminderDate>" as UpdateReminderDate
  , Replicate ("=", 40) + nchar(10)+ "YourSQLDba version: <version> <verdate>" + nchar(10)+ Replicate ("=", 40) as Msg
  ) -- Install.VersionInfo
'
Set @createFct = REPLACE(@createFct, '<version>', (select version from #Version))
Set @createFct = REPLACE(@createFct, '<verDate>', (select convert(nvarchar(10), versionDate, 120) from #Version))
Set @createFct = REPLACE(@createFct, '<UpdateReminderDate>', (select convert(nvarchar(10), getdate()+365, 120)))
Set @createFct = REPLACE(@createFct, '"', '''')
Exec Sp_ExecuteSql @sql, N'@SqlCreateFunction nvarchar(max)', @SqlCreateFunction=@createFct
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Install.PrintVersionInfo'
GO
Create Proc Install.PrintVersionInfo
as
Begin
  declare @versionInfo as nvarchar(500)
  Select @versionInfo = msg from Install.VersionInfo ()
  Print @versionInfo
End
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yInstall.NextUpdateTime'
GO
create function yInstall.NextUpdateTime 
(
)
returns datetime
as
Begin

  return(Select max(convert(datetime, UpdateReminderDate, 120)) from Install.VersionInfo() as f)

End -- yInstall.NextUpdateTime
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUtl.UnicodeCrLf'
GO
Create Function yUtl.UnicodeCrLf
(
)
RETURNS nchar(2)
AS
BEGIN
 Return
 (N'
')
END -- yUtl.UnicodeCrLf
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
go
-- ----------------- fonction yUtl.SplitList ------------------------------------------------------------
-- Function that split a string into a set of rows based on a @sep list
-- -----------------------------------------------------------------------------------------------------------
If OBJECT_ID('yUtl.SplitList') is not null drop function yUtl.SplitList
go
CREATE function yUtl.SplitList (@Sep nvarchar(max), @list nvarchar(max))
returns @items table (item nvarchar(max), seq int)
as
Begin
  declare @start as Int, @Next as Int, @seq as int, @item as nvarchar(max)
  select @start = 1, @seq = 0, @Next = 1
  
  While (@next > 0)
  Begin
    Select @seq = @seq + 1, @Next = CHARINDEX (@Sep, @list, @start)
    If @Next  > 0 
      Set @item = ltrim(SUBSTRING (@list, @start, @next-@start))
    Else  
      Set @item = ltrim(SUBSTRING (@list, @start, len(@list)+1-@start))

    Insert into @items values (nullif (@item, ''), @seq) 
    Set @start = @next+1  
  End
  return  
End
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Exec f$.DropObj 'yUtl.NormalizeLineEnds'
GO
create function yUtl.NormalizeLineEnds  -- line ends can be expressed as a pipe char or a regular line end except if it ends by \
(
  @prm VARCHAR(max) = '' 
)
returns VARCHAR(max)
as
Begin
  -- remove tabs and finish string by '|', turn line ends chars  into '|' and replace multiple consecutives '|' by a single one.
  -- |||| (|) by (.|) done twice because the last one in done on the first time --> '|.|.|.| --> (.|)  by () --> '|'

  Return 
  (
  Select 
    Case 
      When @prm = '' 
      Then '' 
      Else replace(replace(replace(replace(replace (replace(replace(@prm, char(9), '')+'|', nchar(10), '|'), nchar(13), '|'), '||', '|.|'), '||', '|.|'), '.|', ''), '.|', '')
    End
  )
End -- yUtl.NormalizeLineEnds
--Select yUtl.NormalizeLineEnds('
--one
--two
--')
--Select '!'+yUtl.NormalizeLineEnds('')+'!'

GO
-- ------------------------------------------------------------------------------
-- Function to select database from @incDb and @excDb parameters
-- or replace pairs from @replace... parameters
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Exec f$.DropObj 'yUtl.SplitParamInRows'
GO
create function yUtl.SplitParamInRows
(
  @prm VARCHAR(max) = '' 
)
returns @rows table
(
  No int identity 
, line nvarchar(max)
)
as
Begin
  Declare @line nvarchar(max)
  
  -- remove tabs from selection patterns and
  -- add separator at the end of the parameter list, 
  -- so no exception is required in the processing of the list
  
  Set @prm = yUtl.NormalizeLineEnds(@prm)
  
  -- Extract rows and add it to @rows table
  While charindex('|', @Prm) > 0 -- While there is a separator
  Begin
    Set @line = ltrim(rtrim(Left (@Prm, charindex('|', @Prm)-1)))
    -- If it reveals some contents add it
    If @line <> ''  Insert into @rows (line) values (@line)
    -- remove all up to and including '|'
    Set @Prm = Stuff(@Prm, 1, charindex('|', @Prm), '') 
  End

  Return;
End -- yUtl.SplitParamInRows
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUtl.YourSQLDba_ApplyFilterDb'
GO
create function yUtl.YourSQLDba_ApplyFilterDb 
(
  @IncDb VARCHAR(max) = '' -- @IncDb : See following comments for explanation
, @ExcDb VARCHAR(max) = '' -- @ExcDb : See following comments for explanation
)
returns @Db table
(
  DbName               sysname
, dbOwner                sysname
, FullRecoveryMode     int
, cmptLevel            tinyint
)
as
Begin
  -- Create table of inclusion and exclusion patterns that apply to database names
  declare @DbName sysname  

  declare @Pat table
  (
  rech sysname,  -- search pattern
  action char(1) -- 'I' = include if pattern match 'E' = exclude if pattern match 
  ) 

  Insert into @pat Select line, 'I' from yUtl.SplitParamInRows (@IncDb)
  Insert into @pat Select line, 'E' from yUtl.SplitParamInRows (@ExcDb)

-- ===================================================================================== 
-- Build database list to process
-- ===================================================================================== 

  -- Build Db list into temporary table and retain its recovery mode (for possible log backup processing)
  Insert into @Db (DbName, dbOwner, FullRecoveryMode, cmptLevel)
  Select 
    name
  , SUSER_SNAME(owner_sid)
  , Case 
      When DATABASEPROPERTYEX(name, 'Recovery') = 'Simple' 
      Then 0 -- simple recovery mode, no log backup possible
      Else 1 -- full recovery mode, log backup possible
    End as FullRecoveryMode,
    compatibility_level 
  from master.sys.databases 
  Where name <> 'tempdb'

  -- If there is at least one inclusion pattern, remove from database list those that
  -- doesn't match this pattern. Remove from the rest of the list those that match 
  -- with the exclusion pattern
  -- Yes it can be done in one single query ;)
  
  Delete D 
  From 
    @Db D
  Where 
    (   -- only if there is any inclusion pattern 
        Exists     (Select * From @Pat Where Action = 'I') 
        -- delete databases that don't match, otherwise nothing is deleted
    And Not Exists (Select * From @Pat P Where P.action = 'I' And D.DbName like P.Rech)
    )
    -- Suppress any database from the list that match exclusion pattern
    Or Exists (Select * From @Pat P Where P.action = 'E' And D.DbName like P.Rech)

  return
End; -- yUtl.YourSQLDba_ApplyFilterDb 
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUtl.NormalizePath'
GO
-- ------------------------------------------------------------------------------
-- Function that normalize path (ensure that a '\' is at the end of the path
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create function yUtl.NormalizePath
(
  @path nvarchar(512)
)
returns nvarchar(512)
as
Begin
  If right(@path, 1) <> '\'
    Set @path = @path + '\'
  Set @path = left(@path, 2) + replace(substring(@path, 3, 512), '\\', '\')
  return (@path)

-- Some tests
-- Select yUtl.NormalizePath('c:\isql2005Backups')
-- Select yUtl.NormalizePath('c:\isql2005Backups\\')
-- Select yUtl.NormalizePath('c:\isql2005Backups\')
-- Select yUtl.NormalizePath('\\aserver\aShare')
-- Select yUtl.NormalizePath('\\aserver\\aShare')
End -- yUtl.NormalizePath
GO  

-----------------------------
Exec f$.DropObj 'yUtl.SearchWord'
GO
-- Alter 
Create function yUtl.SearchWord
(
  @mot sysname
, @str nvarchar(max)
, @deb int
)
returns int
as
Begin
  -- procédure spécifique à la recherche des mot clés SQL  suivants
  -- char, varchar, text, image, declare, datalength, convert, create table
  -- on ne permet pas que quand on trouve ces chaînes dans le texte
  -- qu'elles soient précédés ou suivies des caractères suivants
  -- qui manifestent qu'ils ne s'agit pas de ces mots clés
  -- les crochets [] on été acceptés de justesse car il y a une colonne
  -- de Edugroupe qui s'appelle Text et pour ne pas convertir la 
  -- table on a mis le nom de colonne entre crochet dans le code.
  -- On peut donc distinguer dans une procédure s'il s'agit en fait 
  -- du type en enlevant les crochets s'il y a lieu, sinon on en met.
  -- .a-z0-9\#/@[]_
  
  Declare @dir Int
  Declare @c Char(1)

  If @deb is NULL Set @deb = 0 -- évite l'initalisation nécessaire de la variable passée en paramètre
  
  Set @dir = @deb

  If @dir < 0 -- reverse la chaîne pour simuler rechercher à reculons
  Begin
    Set @str = reverse(@str)
    Set @mot = reverse(@mot)
    Set @deb = Abs(@deb)
    -- Si chaine se termine par blancs, les blancs de fin sont pas comptés !
    If  @deb > len(@str+'.') Set @deb = len(@str+'.') -1
    Set @deb = len(@str+'.')-@deb
  End

  --print '"'+@mot+'" --> "'+@str+'"'

  Set @deb = @deb-1 -- pour permettre expression commode @deb+1 en partant 
  While(1=1)
  Begin
    set @deb = charindex(@mot, @str, @deb+1)
    --print @deb
    If @deb = 0 Break

    --print substring(@str, @deb-1, 1) 
    If @deb > 1 
    Begin
      Set @c = substring(@str, @deb-1, 1) -- parce  que like boggue quand on a '[' dedans
      If @c like '[.a-z0-9\#/]'  Or @c in ('@','[', '_')
        Continue
    End    

    If @deb + len(@mot) > len(@str)
      Break

    --print substring(@str, @deb + len(@mot), 1)
    set @c = substring(@str, @deb + len(@mot), 1)  -- parce  que like boggue quand on a ']' dedans
    If @c like '[.a-z0-9/#\]'  Or @c in ('@','[', '_')
      Continue

    Break -- si ici on a toutes les conditions ok, donc trouvé
  End

  If @dir < 0 And @deb > 0
    Set @deb = len(@str+'.')-(@deb+len(@mot)-1)

  return (@deb)
End -- yUtl.SearchWord
GO

if objectpropertyEx(object_id('yUtl.SearchWords'), 'isTableFunction') = 1 
  Drop Function yUtl.SearchWords
GO
-- Alter 
Create function yUtl.SearchWords
(
  @mot sysname
, @str nvarchar(max)
)
returns @Tags table 
  (
  posMotCle  int -- pos repere
  )
as
Begin
  Declare @pos int  
  While (1=1)
  Begin
    Set @pos = yUtl.SearchWord(@mot, @str, @pos)  
    If @pos = 0 break
    insert into @Tags (posMotCle)  values(@pos)
    Set @pos = @pos + 1
  End  
  return 
End -- yUtl.SearchWords
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.SilentMode'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
-- ------------------------------------------------------------------------------
-- Function that allows testing of sqlAgent.  Used in InsTohistory and
-- yExecNLog to avoid prints when run from sqlAgent
-- Modify this function to reproduce this behavior from management studio
-- by using this expression Not like 'MicrosoftSQLServerManagementStudio-Query'
-- ------------------------------------------------------------------------------
Create Function yExecNLog.SilentMode ()
Returns int
AS
Begin
  Declare @app sysname
  Declare @appTested sysname
  Set @app = replace (APP_NAME (), ' ', '')
  --Set @appTested = 'MicrosoftSQLServerManagementStudio-Query'
  Set @appTested = '%SqlAgent%'
  Return (case When @app like @appTested Then 1 Else 0 End)
End
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.ErrorPresentInAction'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
-- ------------------------------------------------------------------------------
-- Function that returns rows that have error message into action column
-- in jobHistorydetails
-- ------------------------------------------------------------------------------
Create Function yExecNLog.ErrorPresentInAction (@action XML)
Returns int
AS
Begin
  Return 
  (
  @action.exist('/Exec/err//text()[contains(.,"")]') | @action.exist('/Step/err//text()[contains(.,"")]') | @action.exist('/row/err//text()[contains(.,"")]')
  )         
End
go
-- --------------------------------------------------------------------------------------------
-- Return SQL code or XML text string in multi-rows, 1 row per code line
-- Workround of the 8000 char limit when printing SQL code.
-- --------------------------------------------------------------------------------------------
create FUNCTION yExecNLog.SqlCodeLinesInResultSet 
(
@sql nvarchar(max)
)
RETURNS @TxtSql TABLE (i int identity (0, 1), txt nvarchar(max))
AS 
Begin
  declare @i int, @d Datetime
  If @i > 0
    Insert into @txtSql (txt) 
    values ('-- Seq:'+ltrim(str(@i))+
            ' Time:'+convert(nvarchar(20), @d, 120) +  ' ' + replicate('-', 10) )

  If @sql is null Or @sql = ''
  Begin
    Insert into @txtSql (txt) values ('')
    return
  End

  declare @Start int, @End Int, @line nvarchar(max), @EOLChars int
  Set @Start = 1 Set @End=0

  -- Normalize end-of-line
  -- Sql server interpret first #13#10 as a valid end-of-line otherwise #10
  -- If #10#13 is found it is shown a two end-of-line
  Set @sql = REPLACE(@sql, nchar(13)+nchar(10), nchar(10)) -- normalize #13#10 -> #10
  Set @sql = REPLACE(@sql, nchar(13), nchar(10)) -- normalize #10#13 -> #10#10 -- shown like this in normal SSMS output

  While(1=1)
  Begin
    Set @end = charindex(nchar(10), @Sql, @Start)
    If @End = 0 
    Begin
      Set @line = Substring(@sql, @Start, len(@sql)-@Start+1) 
      Break
    End  
    Else   
      Set @line = Substring(@sql, @Start, @End-@Start+1)
      
    Set @Start = @End+1
    Insert into @txtSql (txt) 
    values (replace (replace (@line, nchar(10), ''), nchar(13), ''))
  End
  RETURN
End -- yExecNLog.SqlCodeLinesInResultSet
go

-- ------------------------------------ yExecNLog.PrintSqlCode ----------------------------------
-- Use yExecNLog.SqlCodeLinesInResultSet for sql code printing purposes
-- ----------------------------------------------------------------------------------------------------------
CREATE Procedure yExecNLog.PrintSqlCode
  @sql nvarchar(max)
, @numberingRequired int = 0
AS 
Begin
  Set nocount on

  If @Sql IS NULL
  Begin
    Print 'Bug : Query text parameter is null !!'
    return
  End

  declare @codeLines table (i int primary key, txt nvarchar(max))
  insert into @codeLines (i, txt)
  Select i, txt
  From yExecNLog.SqlCodeLinesInResultSet (@sql)
  
  Declare @Seq Int
  Declare @Line nvarchar(max)

  Set @seq = -1
  While (1=1)
  Begin
    Select top 1 @Seq = i, @line = txt   
    from @codeLines 
    Where i > @seq
    Order by i
    
    If @@ROWCOUNT = 0 break
    
    If @numberingRequired = 0
      Print @line
    Else
      Print Str(@seq,5)+' '+@line
  End
  
  --Set @Line = Str(@seq,5)+' line(s) printed'
  raiserror (@line,10,1) with nowait -- force print output

End -- yExecNLog.PrintSqlCode
GO

-- ------------------------------------------------------------------------------
-- Procedure that execute dynamic T-SQL or simply log maintenance messages
-- It also record execution error when this apply
-- When @sql parameter is empty string, only informational info is logged
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.InsToHistory'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc yExecNLog.InsToHistory 
  @YourSqlDbaNo nvarchar(max) = NULL
, @context nvarchar(4000) = NULL
, @sql varchar(max) = NULL  -- done on purpose to resolve issues due to unicode illegal character for XML
, @Info varchar(max) = NULL -- done on purpose to resolve issues due to unicode illegal character for XML
, @err varchar(max) = NULL -- done on purpose to resolve issues due to unicode illegal character for XML
, @JobNo Int = NULL
, @seq int = NULL output
, @forDiagOnly  bit = 0  -- flag = 1 when not to be shown by default by Maint.showHistory
as
Begin
  set nocount on
  declare @action nvarchar(max)
  
  declare @xml xml
  Select @xml =
    yExecNLog.Clr_RemoveCtlChar
    (
      ( -- FOR XML treat NULL values in elements as making elements absent, this is very convenient here
      Select -- convoluted trick to make xml data cdata, no other method than XML Explicit
        @context as ctx
      , @yoursqldbaNo as YSDNo
      , @Sql as Sql -- workaround to recover new line lost when making XML
      , @Info as inf
      , @err  as err
      For XML Path
      )
    )
  Set @action = replace(convert(nvarchar(max), @xml), '&#x0D', NCHAR(13)+NCHAR(10)) -- recovering new line lost when making xml  
  Insert into  Maint.JobHistoryDetails (JobNo, Action, forDiagOnly) Values (@JobNo, @xml, @ForDiagOnly)
  Set @seq = SCOPE_IDENTITY ()
  
  -- When not ran form sqlagent, let error messages go through
  -- when run from the agent keep yoursqldba silent
  --If @appName Not like '%SqlAgent%' 
  If yExecNLog.SilentMode () = 0  -- for testing no print
  Begin
    -- Some messages are just intended for logging purpose into the yoursqldba's history table
    -- by default all messages are printed when not ran from SqlAgent
    -- the execption The printMsg flag requires in all cases to print it
    -- Non-Diagnostics messages are also printed
    If @forDiagOnly  <> 1
    Begin
      If @err not like 'In case of non-completion of this command check SQLServer Error Log%' 
      
        exec yExecNLog.PrintSqlCode @sql = @action, @numberingRequired = 0
    End  
  End
End
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Exec f$.DropObj 'yExecNLog.IfSqlAgentJobGetJobIdAndStepId'
GO
create procedure yExecNLog.IfSqlAgentJobGetJobIdAndStepId 
  @jobId uniqueIdentifier = null output 
, @stepId int = null output
as
Begin
  Declare @pgm nvarchar(512)
  Declare @pos int
  Declare @jobIdStr nvarchar(40)
  Declare @sql nvarchar(max)
  
  Set @jobId = 0x
  Set @StepId = 0
  
  Select @pgm = replace(app_name(), ' ', '')
  
  If @pgm not like 'SQLAgent-TSQLJobStep(Job%:Step%)%'
  Begin
    -- Print 'The job identification is "' + @pgm + '"'
    return
  End  

  Set @pgm = replace(@pgm,  'SQLAgent-TSQLJobStep(Job', '')
  set @pos = charindex(':Step', @pgm)
  If @pos = 0 -- :step tag is not there
    return
  
  -- get @jobid and remove it from the string
  Set @jobIdStr = left(@pgm, @pos-1)
  -- Print '@jobIdStr = "' + @jobIdStr + '"'
  Set @sql = 'Set @jobId = convert(uniqueidentifier, '+@jobIdStr+')'
  exec sp_executeSql @Sql, N'@jobId uniqueidentifier output', @jobId output
  
  -- Print '@jobId = "' + convert(nvarchar(max), @jobId) + '"'

  Set @pgm = replace(@pgm, @jobIdStr+':Step', '') -- remove jobId+step 
  Set @pgm = replace (@pgm, ')', '') -- remove last ')'
  
  -- should remain only digits
  If @pgm like '%[^0-9]%' -- no non-digits
  Begin
    Set @jobId = 0x
    return
  End 
  
  -- got it all
  Set @stepId = convert(int, @pgm)
  -- Print '@stepId = "' + @pgm + '"'
End -- yExecNLog.IfSqlAgentJobGetJobIdAndStepId
GO

-- ------------------------------------------------------------------------------
-- Procedure that create-manage new jobs entries
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.AddJobEntry'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc yExecNLog.AddJobEntry
  @jobName nvarchar(512)
, @jobNo int = NULL output
as
Begin
  -- This procedure is called once in maintenance job to get the jobNo.
  -- When a jobNo is known it is no more called in the job.
  -- For ad-hoc queries it ia always called since job no is not carried around
  -- so we try to reuse last job entry for ah-hoc queries
  -- it there is no more recent job which are not ah-hoc.
  Declare @jobId uniqueidentifier
  Declare @stepid int

  Set @jobNo = NULL

  -- don't really add a new job entry for ad-hoc operations
  -- if there is no job newer than the current one.
  If @jobName Like 'Ad-Hoc%' -- AdHoc stuff 
  Begin
    select top 1 @jobNo = jobNo
    from Maint.JobHistory 
    Where JobName like 'Ad-Hoc%'
      And spid = @@spid
    order by JobNo Desc

    If exists(select * from Maint.JobHistory Where JobNo > @jobNo)
      Set @jobNo = NULL
  End
  Else    
    exec yExecNLog.IfSqlAgentJobGetJobIdAndStepId @jobId output, @stepId output
  
  If @jobNo is NULL  -- still null, add a new job
  Begin
    Insert into Maint.JobHistory (JobName, JobStart, JobId, StepId) 
    Select @jobName, GETDATE(), @jobId, @StepId
    Set @JobNo = scope_identity()    
  End  
  
End -- yExecNLog.AddJobEntry
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.ExecWithProfilerTrace'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
-- ------------------------------------------------------------------------------
-- This procedure wraps the call to the clr_exec
Create Procedure yExecNLog.ExecWithProfilerTrace @sql nvarchar(max), @maxSeverity int output, @Msgs nvarchar(max) = '' output
as
Begin
  Set @MaxSeverity = 0
  Exec yExecNLog.Clr_ExecAndLogAllMsgs @sqlcmd=@sql, @maxSeverity=@maxSeverity output, @msgs=@msgs output
  
  If @sql is null Set @sql = ''
  If @msgs is null Set @msgs = ''

  -- produce something that profiler can display of the dynamic query launched, and error messages and warnings if any
  Exec(
  'declare @i int; set @i = 1 
  /* YourSqlDba profiler trace as a dummy instruction to Show Clr_ExecAndLogAllMsgs @sql param and @msgs output 
  ===============================================================================================
  '+@sql+'
  -----------------------------------------------------------------------------------------------
  '+@msgs+'
  ===============================================================================================
  */'
  )
End
Go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.LogAndOrExec'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
-- ------------------------------------------------------------------------------
-- When @err is already specified ignore @sql parameter. 
-- The intent is to log high level error messages

-- When @err is missing, @Info or @context specified but @sql = '' by parameter omission, 
-- intent is to log pure informational messages

-- When @sql parameter is not empty, it must be run dynamically and any error messages
-- would be loggued.  By precaution, a message is written in case the command should
-- not return because of a high severity error.

-- @Sql should never be null, this is a programming error that happens when 
-- a part that is used to build the dynamic query is unexpectedly left null.
-- this is loggued as an important debugging aid, because dynamic execution of
-- a null Sql command leave otherwise no error message
-- ------------------------------------------------------------------------------
create proc yExecNLog.LogAndOrExec 
  @YourSqlDbaNo nvarchar(max) = NULL
, @context nvarchar(4000) = NULL
, @sql nvarchar(max) = '' -- this is a convenient way to know if LogAndOrExec was called without SQL command
, @Info nvarchar(max) = NULL
, @err nvarchar(max) = NULL Output -- input : err msg to be written to log; output: error generated by an sql execution
, @JobNo Int = NULL Output
, @errorN Int = 0 Output
, @raiseError int = 0 
, @forDiagOnly  int = 0
as
Begin
  Set nocount on
  Declare @seq Int
  Declare @NbOfLn Int
  Declare @Msgs varchar(max)  -- spcified as varchar(max) to auto convert unicode character to convertable char to xml
  Declare @maxSeverity Int
  Declare @newJobName nvarchar(128)
  Declare @xml xml
  
  Set @errorN = 0 
  
  Begin TRY
    -- to make things simple for single ad-hoc operations
    -- by default the job name is generated here
    -- AddJobEntry make ad_hoc job to be reuse as long as there is no
    -- newer job than the last one create for ad-hoc operations.
    If @JobNo IS NULL
    Begin
      exec yExecNLog.AddJobEntry 
             @jobName = 'Ad-hoc action'
           , @JobNo = @JobNo output -- new or actual job
    End       

    -- Unindent T-SQL to have leftmost code to start in column one
    If @sql <> ''
      Set @sql = yExecNLog.Unindent_TSQL(@sql)
      
    If @err = '?'
      Set @err = yExecNLog.FormatBasicBeginCatchErrMsg ()  

    If @err is not null
      -- intent : This procedure was called just to log error message that comes 
      -- from the calling proc.  in that case if we log an SQL command
      -- we will log it through the @Info parameter.
      Exec yExecNLog.InsToHistory  
        @YourSqlDbaNo = @YourSqlDbaNo
      , @context = @context
      , @Info = @Info
      , @err = @err
      , @JobNo = @jobNo
      , @forDiagOnly = @forDiagOnly 
      , @seq = @seq output 
    Else   
    Begin
      -- intent : This procedure was called just to log informational message
      -- @sql = '' being the default value, @sql is made empty by parameter omission;
      -- the caller didn't made the call to execute some @sql.
      -- When @sql is NULL this is an error situation that made it null
      -- with the first intent to execute real @sql, otherwise @sql should be different than ''
      If (@Info is not null Or @context is not null) And (@sql is not null and @sql = '')
        Exec yExecNLog.InsToHistory 
          @YourSqlDbaNo = @YourSqlDbaNo
        , @context = @context
        , @Info = @Info
        , @JobNo = @jobNo
        , @forDiagOnly = @forDiagOnly 
        , @seq = @seq output 
      Else
      Begin
        -- intent : There was some @sql to run because the two previous methods 
        --          where not used (@err not null or @info or @context not null)
        --          This is the third mandatoty use of this proc.  @Sql should be complete and <> ''
        
        -- @sql has to be specified and it should differ from ''
        
        -- If the generated @SQL turns out to be NULL because some elements that are used
        -- to generate it are NULL, it overrides also the default value as it would happen 
        -- with a correct @sql value.
        
        -- Before running any SQL statement we record a pre-error message in case the command would generate
        -- an high enough severity error that would make the connection to be dropped.
        -- If the call returns, we will override into the log table the pre-recorded  message with either 
        -- no error ot any other error that was returned depending on the issue of the query
        If @sql IS NULL
          Set @err = 'NULL Value for generated SQL command';
        Else  
          Set @err = 'In case of non-completion of this command check SQLServer Error Log at ' + 
                     CONVERT(nvarchar, getdate(),121)+ ' for Spid ' + Convert(nvarchar, @@spid)
        
        -- if @err like 'In case of non-completion of this command check SQLServer Error Log at%'     
        -- InstoHistory doesn't print the command otherwise it always does it when @err <> '' and is not null
        Exec yExecNLog.InsToHistory  
          @YourSqlDbaNo = @YourSqlDbaNo
        , @context = @context
        , @Info = @Info
        , @sql = @sql
        , @err = @err
        , @JobNo = @jobNo
        , @seq = @seq output 
        , @forDiagOnly  = @forDiagOnly  -- avoid prints at exec. if zero but always print when @err <> ''
      End    
    End

    -- if a real @sql command has to be run, try run it. Then write over any error or no error + informative message over
    -- the "in case of non-completion... " message left there in case a high severity error would make ExecAndLogAllMsgs
    -- not to return
    If isnull(@sql, '') <> '' 
    Begin
      Declare @txtMsgInCaseOfImpossibleXmlConversion nvarchar(max)
      Declare @xmlToText nvarchar(max)
      Exec yExecNLog.ExecWithProfilerTrace @sql, @maxSeverity output, @Msgs Output  
      Set @errorN = Case when @maxSeverity > 10 then 1 Else 0 End; 

      Begin Try
        If @maxSeverity <= 10
          Set @Xml = -- rebuild original message inserted into JobHistoryDetails
          yExecNLog.Clr_RemoveCtlChar
          (
            (
            Select
              @yoursqldbaNo as YSDNo
            , @context as ctx
            , @Info as inf
            , @Sql as Sql
            , @Msgs as Msgs -- create an element <Msgs> is there is no error message which is known with @maxSeverity<=10
            For XML Path('Exec')
            )       
          )
        Else
          Set @Xml = -- rebuild original message inserted into JobHistoryDetails
          yExecNLog.Clr_RemoveCtlChar
          (
            (
            Select
              @yoursqldbaNo as YSDNo
            , @context as ctx
            , @Info as inf
            , @Sql as Sql
            , @Msgs as err -- create an element <err> if there is among error messages a message which is known with @maxSeverity<=10
            For XML Path('Exec')
            )       
          )
        If @errorN >0 
          Set @err = @Msgs;
      End try
      Begin catch
        Set @err = yExecNLog.FormatBasicBeginCatchErrMsg ()
        Set @txtMsgInCaseOfImpossibleXmlConversion  = 
            '
            This text can''t be saved to XML format into JobHistoryDetails
            ---------------------------------------------
            Context : 
            '+@context+
            '---------------------------------------------
            Info :
            '+@Info+
            '---------------------------------------------
            Sql :
            '+@Sql+
            '---------------------------------------------
            Msgs :
            '+@Msgs

        Exec yExecNLog.PrintSqlCode @txtMsgInCaseOfImpossibleXmlConversion, 1
      End catch
      
      -- bypass normal InsToHistory since the job is already done.
      Update Maint.JobHistoryDetails 
      Set 
        secs = Datediff(ss, cmdStartTime, getdate())
      , action = @Xml
      , forDiagOnly = Case When @maxSeverity > 10 Then 0 Else @forDiagOnly End
      Where JobNo = @JobNo And seq = @seq
      
      -- If not in silent mode (like when run from agent)
      --   perform a print in case of an error (@maxSeverity > 10)
      --   or for all messages that aren't just logged as diagnostics helpers
      If yExecNLog.SilentMode () = 0 
        If @maxSeverity > 10 Or @forDiagOnly = 0
        Begin
          set @xmlToText = yExecNLog.Clr_XmlPrettyPrint (@Xml)
          exec yExecNLog.PrintSqlCode @sql = @XmlToText, @numberingRequired = 0
        End

      If @maxSeverity > 10 And @raiseError = 1
        Raiserror ('Stop on error by demand of calling procedure for :  %s : %s ',11,1, @YourSqlDbaNo, @context)
      else  
        return 1
    End  

  End TRY
  Begin CATCH  
    Set @errorN = 1;
    Set @err = yExecNLog.FormatBasicBeginCatchErrMsg ()
    Exec yExecNLog.InsToHistory 
      @context = @context
    , @Info = @Info
    , @err = @err
    , @JobNo = @jobNo
    , @seq = @seq output 
  End CATCH

  return 0  

End -- yExecNLog.LogAndOrExec
GO
Exec f$.DropObj 'yMaint.CollectBackupHeaderInfoFromBackupFile'
go
Create Procedure yMaint.CollectBackupHeaderInfoFromBackupFile @bkpFile nvarchar(512)
as
Begin
  Declare @sql nvarchar(max)

  Create Table #Header 
  (
	  BackupName nvarchar(128),
	  BackupDescription nvarchar(255),
	  BackupType smallint,
	  ExpirationDate datetime,
	  Compressed tinyint,
	  Position smallint,
	  DeviceType tinyint,
	  UserName nvarchar(128),
	  ServerName nvarchar(128),
	  DatabaseName nvarchar(128),
	  DatabaseVersion int,
	  DatabaseCreationDate datetime, 
	  BackupSize numeric(20,0),
	  FirstLSN numeric(25,0),
	  LastLSN numeric(25,0),
	  CheckpointLSN numeric(25,0),
	  DatabaseBackupLSN numeric(25,0),
	  BackupStartDate datetime,
	  BackupFinishDate datetime,
	  SortOrder smallint,
	  CodePage smallint,
	  UnicodeLocaleId int,
	  UnicodeComparisonStyle int,
	  CompatibilityLevel tinyint,
	  SoftwareVendorId int,
	  SoftwareVersionMajor int,
	  SoftwareVersionMinor int,
	  SoftwareVersionBuild int,
	  MachineName nvarchar(128),
	  Flags int,
	  BindingID uniqueidentifier,
	  RecoveryForkID uniqueidentifier,
	  Collation nvarchar(128),
	  FamilyGUID uniqueidentifier,
	  HasBulkLoggedData bit,
	  IsSnapshot bit,
	  IsReadOnly bit,
	  IsSingleUser bit,
	  HasBackupChecksums bit,
	  IsDamaged bit,
	  BeginsLogChain bit,
	  HasIncompleteMetaData bit,
	  IsForceOffline bit,
	  IsCopyOnly bit,
	  FirstRecoveryForkID uniqueidentifier,
	  ForkPointLSN numeric(25,0),
	  RecoveryModel nvarchar(60),
	  DifferentialBaseLSN numeric(25,0),
	  DifferentialBaseGUID uniqueidentifier,
	  BackupTypeDescription nvarchar(60),
	  BackupSetGUID uniqueidentifier
  )

  -- adjust table column depending on version
  -- sql2008 need CompressedBackupSize column
  If yInstall.SqlVersionNumber () >= 100  -- sql 2008 and above
    Alter table #Header Add CompressedBackupSize BigInt
 
  -- sql2012 need containement column
  If yInstall.SqlVersionNumber () >= 110  -- sql 2012 and above
    Alter table #Header Add containment tinyint

  -- sql2014 need theses 
  If yInstall.SqlVersionNumber () >= 120  -- sql 2014 and above
  Begin
    Alter table #Header Add KeyAlgorithm nvarchar(32)
    Alter table #Header Add EncryptorThumbprint varbinary(10)
    Alter table #Header Add EncryptorType nvarchar(32)
  End

  Set @sql = 'Restore HeaderOnly from Disk="<nf>"'
  Set @sql = replace(@sql, '<nf>', @bkpFile)
  Set @Sql = 
  '
  insert into #Header
  exec ("'+replace(@sql, '"', '""')+'")
  '
  Set @Sql = replace (@sql, '"', '''')
  Set @sql = yExecNLog.Unindent_TSQL(@sql)
  Declare @maxSeverity int
  Declare @msgs Nvarchar(max)
  Exec yExecNLog.ExecWithProfilerTrace @sql, @MaxSeverity output, @Msgs output

  Delete From Maint.TemporaryBackupHeaderInfo Where spid = @@spid

  If @maxSeverity > 10 
  Begin
    Raiserror (N'CollectBackupHeaderInfoFromBackupFile error %s: %s %s', 11, 1, @@SERVERNAME, @Sql, @Msgs)    
    Return (1)
  End

  Insert into Maint.TemporaryBackupHeaderInfo (BackupType, position, deviceType, DatabaseName, lastLsn)
  Select BackupType, position, deviceType, DatabaseName, lastLsn 
  From #Header
  Return(0)
End
Go
Exec f$.DropObj 'yMaint.CollectBackupFileListFromBackupFile'
go
Create Procedure yMaint.CollectBackupFileListFromBackupFile @bkpFile nvarchar(512)
as
Begin
  Declare @sql nvarchar(max)

  create table #Files -- Database file list obtained from restore filelistonly
  (
   LogicalName nvarchar(128) -- Logical name of the file.
  ,PhysicalName nvarchar(260) -- Physical or operating-system name of the file.
  ,Type NCHAR(1) -- The type of file, one of: L = Microsoft SQL Server log file D = SQL Server data file F = Full Text Catalog 
  ,FileGroupName nvarchar(128) -- Name of the filegroup that contains the file.
  ,Size numeric(20,0) -- Current size in bytes.
  ,MaxSize numeric(20,0) -- Maximum allowed size in bytes.
  ,FileID bigint -- File identifier, unique within the database.
  ,CreateLSN numeric(25,0) -- Log sequence number at which the file was created.
  ,DropLSN numeric(25,0) NULL -- The log sequence number at which the file was dropped. 
                              -- If the file has not been dropped, this value is NULL.
  ,UniqueID uniqueidentifier -- Globally unique identifier of the file.
  ,ReadOnlyLSN numeric(25,0) NULL -- Log sequence number at which the filegroup containing the file changed 
                                  -- from read-write to read-only (the most recent change).
  ,ReadWriteLSN numeric(25,0) NULL  -- Log sequence number at which the filegroup containing the file changed 
                                    -- from read-only to read-write (the most recent change).
  ,BackupSizeInBytes bigint -- Size of the backup for this file in bytes.
  ,SourceBlockSize int -- Block size of the physical device containing the file in bytes (not the backup device).
  ,FileGroupID int -- ID of the filegroup.
  ,LogGroupGUID uniqueidentifier NULL -- NULL. 
  ,DifferentialBaseLSN numeric(25,0) NULL -- For differential backups, changes with log sequence numbers greater than or equal 
                                          -- to DifferentialBaseLSN are included in the differential. 
  ,DifferentialBaseGUID uniqueidentifier -- For differential backups, the unique identifier of the differential base. 
  ,IsReadOnly bit -- 1 = The file is read-only.
  ,IsPresent bit -- 1 = The file is present in the backup.
  )

  -- sql2008 need TDEThumbprint column
  If yInstall.SqlVersionNumber () >= 100  -- sql 2008 and above
    Alter table #Files Add TDEThumbprint varbinary(32)
    
  If yInstall.SqlVersionNumber () >= 120
    Alter Table #Files Add SnapshotURL Nvarchar(36)
 
  Set @sql = 'Restore filelistonly from Disk="<nf>"'
  Set @sql = replace(@sql, '<nf>', @bkpFile )
  Set @Sql = 
  '
  insert into #Files
  exec ("'+replace(@sql, '"', '""')+'")
  '
  Set @Sql = replace (@sql, '"', '''')
  Set @sql = yExecNLog.Unindent_TSQL(@sql)

  Declare @maxSeverity int
  Declare @msgs Nvarchar(max)
  Exec yExecNLog.ExecWithProfilerTrace @sql, @MaxSeverity output, @Msgs output

  Delete From Maint.TemporaryBackupFileListInfo Where spid = @@spid

  If @maxSeverity > 10 
  Begin
    Raiserror (N'CollectBackupFileListFromBackupFile error %s: %s %s', 11, 1, @@SERVERNAME, @Sql, @Msgs)    
    Return (1)
  End

  Insert into Maint.TemporaryBackupFileListInfo (FileId, Type, LogicalName, physicalName)
  Select FileId, Type, LogicalName, physicalName
  From #Files

  Return (0)
End
Go

Exec f$.DropObj 'yMaint.SaveXpCmdShellStateAndAllowItTemporary'
GO
Create Proc yMaint.SaveXpCmdShellStateAndAllowItTemporary
as
Begin
  If Exists(Select * from Maint.XpCmdShellSavedState) 
  Begin
    Exec 
    (
    '
    With XpCmdShellState
    as
    (
    Select convert(int,value_In_Use) as Value_in_use
    from 
      Sys.configurations 
    Where name =  ''xp_cmdshell''
    )
    Update Maint.XpCmdShellSavedState
    Set value_In_Use = S.Value_in_use
    From XpCmdShellState S
    '
    )
  End
  Else
    Exec 
    (
    '
    With XpCmdShellState
    as
    (
    Select convert(int,value_In_Use) as Value_in_use
    from 
      Sys.configurations 
    Where name =  ''xp_cmdshell''
    )
    Insert Into Maint.XpCmdShellSavedState (value_In_Use)
    Select * from XpCmdShellState
    '
    )
  
  EXEC sp_configure 'xp_cmdshell', 1
  Reconfigure
End
GO
Exec f$.DropObj 'yMaint.RestoreXpCmdShellState'
GO
Create Proc yMaint.RestoreXpCmdShellState
as
Begin
  If OBJECT_ID('Maint.XpCmdShellSavedState') IS Not NULL
  Begin
    Exec 
    (
    '
    Declare @state int
    Select @state=convert(int, value_In_Use)
    From Maint.XpCmdShellSavedState

    EXEC sp_configure ''xp_cmdshell'', @state
    Reconfigure
    
    Delete Maint.XpCmdShellSavedState
    '
    )
  End
End
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.PutDbOffline'
GO
Create proc yMaint.PutDbOffline 
  @DbToLockOut nvarchar(128) = ''
, @JobNo Int
as
Begin
  Declare @AlterDb nvarchar(512)
  Declare @Info nvarchar(512)

  If DatabasepropertyEx(@DbToLockOut, 'Status') <> 'EMERGENCY'  And 
     @DbToLockOut Not In ('master', 'model', 'msdb')
  Begin
    If DatabasepropertyEx(@DbToLockOut, 'Status') <> N'ONLINE' 
      Return -- version 1.1 don't attempt to put offline a database that is already not online
      
    Set @AlterDb = 
    '
    Alter database [<db>] Set offline With ROLLBACK immediate
    '
    
    Set @Info = 'Database [<db>]is put offline because the previous error'

    Set @AlterDb = Replace(@AlterDb, '<db>', @DbToLockOut)
    Set @Info = Replace(@Info, '<db>', @DbToLockOut)
    Set @AlterDb = Replace(@AlterDb, '"', '''')

    Begin try
    
    Exec (@alterDb)
    
    Exec yExecNLog.LogAndOrExec 
      @context = @Info
    , @YourSqlDbaNo = '005'
    , @JobNo = @JobNo
    
    End try
    begin catch
      Exec yExecNLog.LogAndOrExec 
        @context = 'yMaint.PutDbOffline error'
      , @err='?'
      , @YourSqlDbaNo = '005'
      , @JobNo = @JobNo
    end catch
    

  End
End -- yMaint.PutDbOffline 
GO
-- ---------------------------------------------------------------------------------------
-- This procedures extract informations required for database mail diagnosis
-- ---------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.DiagDbMail'
GO
create Procedure Maint.DiagDbMail 
as
Begin
  -- Lire les éléments envoyés
  -- Voir la queue de message SQL
  EXEC msdb.dbo.sysmail_help_queue_sp @queue_type = 'mail' ;
  SELECT top 5 S.send_request_date, S.mailItem_id, S.sent_status, S.recipients, s.subject 
  FROM msdb.dbo.sysmail_sentitems S
  order by S.sent_date desc, S.mailItem_id desc;
  SELECT top 100 * 
  FROM msdb.dbo.sysmail_event_log order by log_id desc;
End -- Maint.DiagDbMail
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUtl.ConvertToHexString'
GO
Create function yUtl.ConvertToHexString
(
  @binValue varbinary(max)
)
returns nvarchar(max)
as
Begin
  DECLARE @charvalue nvarchar (max)
  DECLARE @i         int
  DECLARE @length    int
  Declare @pwdHexString Char(16)

  If @Binvalue IS NULL
    RETURN (N'NULL')

  SELECT @charvalue = '0x'
  SELECT @i = 1
  SELECT @length = datalength (@binvalue)
  SELECT @pwdHexString = '0123456789ABCDEF'

  WHILE (@i <= @length)
  BEGIN
    DECLARE @tempint   int
    DECLARE @firstint  int
    DECLARE @secondint int

    Set @tempint = CONVERT (int, SUBSTRING (@binvalue, @i, 1))
    Set @firstint = FLOOR (@tempint / 16)
    Set @secondint = @tempint - (@firstint * 16)

    Set @charvalue = @charvalue +
      SUBSTRING (@pwdHexString, @firstint + 1, 1) +
      SUBSTRING (@pwdHexString, @secondint + 1, 1)

    Set @i = @i + 1
  END

  return(@charvalue)
End -- yUtl.ConvertToHexString
GO
--select * 
--from 
--yUtl.YourSQLDba_ApplyFilterDb (
--'
--',
--'
--F%'
--)
--GO
----------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Tools.CompareRows'
GO
-------------------------------------------------------------------------------------
-- This highly flexible procedure allows rows comparison from many different sources. 
-- It could be a table (with an optional filter), or a query.  It can reside into the 
-- same database, or onto different database, on the same server or on 
-- different servers, provide that the necessary linked server are defined.  
-- Both source and target are independently configurable
-- The only condition is that they returns the same columns.  
-- Generated query is printed for debugging purposes.
-- Column list is mandatoty, and at least one row source for the source and the target.
---------------------------------------------------------------------------------------
If OBJECT_ID('Tools.CompareRows') is not null drop procedure Tools.CompareRows
go
create proc Tools.CompareRows 
  @ColList nvarchar(max)  -- list of columns to compare (must include primary key)
, @Srctab as sysname = '' -- schema mandatory, could be substituted by @SrcQry 
, @SrcQry as nvarchar(max) = '' -- if specified override @SrcTab, must include db.schema
, @TgtTab as sysname = '' -- schema mandatory, could be substituted by @TgtQry 
, @TgtQry as nvarchar(max) = '' -- if specified override @TgtTab, must include db.schema
, @SrcWhereClause nvarchar(max) = '' -- optional where clause for @srcTab 
, @TgtWhereClause nvarchar(max) = '' -- optional where clause for @TgtTab
, @SrcDB as sysname = '' -- source db (default to current one)
, @TgtDB as Sysname = '' -- target db (default to source)
, @SrcInstance as sysname = '' -- linked source server, default local
, @TgtInstance as sysname = '' -- linked target server, default local 
as
Begin
  declare @sql nvarchar(max)
  set @sql = 
  '
  With SrcRows as
  (
  <SrcQry>
  )
  , tgtRows As
  (
  <TgtQry>
  )
  , UnionOfDataSetsToCompare as
  (
  Select "(source) [<SrcInstance>].[<SrcDB>].<SrcTab>" as DataSetId
  , <ColList>
  From SrcRows
  UNION ALL 
  Select "(target) [<TgtInstance>].[<TgtDB>].<TgtTab>" as DataSetId
  , <ColList>
  From TgtRows
  )
  select 
    MAX(DataSetId) as DataSetid
  , <ColList>
  from UnionOfDataSetsToCompare
  group by 
    <ColList>
  Having MAX(DataSetId) = MIN(DataSetId)
  order by 
    <ColList>
  '
  -- assume some behavior for missing parameters
  If @SrcDB = '' Set @SrcDB = DB_NAME() -- current db if no @SrcDb
  If @TgtDB = '' Set @TgtDB = @SrcDB -- Same db if no @tgtDg
  If @TgtTab = '' Set @TgtTab = @Srctab -- Same table name if no @TgtTab
  If @TgtWhereClause = '' Set @SrcWhereClause = @TgtWhereClause 
  If @SrcQry <> '' Set @sql = REPLACE(@sql, '<SrcQry>', @SrcQry)
  If @TgtQry = '' And  @TgtTab = '' Set  @TgtQry = @SrcQry
  If @TgtQry <> '' Set @sql = REPLACE(@sql, '<TgtQry>', @TgtQry)
  
  If @Srctab = '' Set @sql = REPLACE(@sql, '(source) [<SrcInstance>].[<SrcDB>].<SrcTab>'
                                         , '@SrcQry')
  If @Tgttab = '' Set @sql = REPLACE(@sql, '(target) [<TgtInstance>].[<TgtDB>].<TgtTab>'
                                         , '@TgtQry')
  
  If @Srctab = '' And @SrcQry = '' 
  Begin
    Print 'Provide either @srcTab or @srcQry parameter'
    Return
  End
    
  Set @sql = REPLACE(@sql, '<SrcQry>', 
  'Select
    <ColList>
  from [<SrcInstance>].[<SrcDB>].<SrcTab>
  <SrcWhereClause>')

  Set @sql = REPLACE(@sql, '<TgtQry>', 
  'Select 
    <ColList>
  from [<TgtInstance>].[<TgtDB>].<TgtTab>
  <TgtWhereClause>')

  -- replace tags
  Set @sql = REPLACE (@sql, '<ColList>', @ColList)
  Set @sql = REPLACE (@sql, '<SrcTab>', @Srctab)
  Set @sql = REPLACE (@sql, '<TgtTab>', @Tgttab)
  Set @sql = REPLACE (@sql, '<SrcWhereClause>', @SrcWhereClause)
  Set @sql = REPLACE (@sql, '<TgtWhereClause>',@TgtWhereClause)
  Set @sql = REPLACE (@sql, '<SrcDB>', @SrcDB )
  Set @sql = REPLACE (@sql, '<TgtDB>', @TgtDB )
  
  -- remove the linked server syntax part if not specified
  If @SrcInstance = '' Set @sql = REPLACE (@sql, '[<SrcInstance>].', '')
  Set @sql = REPLACE (@sql, '<SrcInstance>', @SrcInstance )

  If @TgtInstance = '' Set @sql = REPLACE (@sql, '[<TgtInstance>].', '')
  Set @sql = REPLACE (@sql, '<TgtInstance>', @TgtInstance )

  -- replace double quotes by real single quotes
  Set @sql = REPLACE (@sql, '"', '''')
  
  Exec yExecNLog.PrintSqlCode @sql, @numbering=1 -- show the query for debugging purpose
  exec (@sql) -- execute it
End
go

--exec Tools.CompareRows
--  @ColList = 'ContactID, NameStyle, Title, FirstName, MiddleName, LastName, Suffix
--             , EmailAddress, EmailPromotion, Phone, PasswordHash, PasswordSalt, rowguid
--             , ModifiedDate'
--, @Srctab = 'Person.Contact'
--, @SrcDb = 'AdventureWorks'
--, @TgtDb = 'AdventureWorksCopy'

--exec Tools.CompareRows
--  @ColList = 'ContactID, NameStyle, Title, FirstName, MiddleName, LastName, Suffix
--             , EmailAddress, EmailPromotion, Phone, PasswordHash, PasswordSalt, rowguid
--             , ModifiedDate'
--, @SrcQry = 'Select * from AdventureWorks.Person.Contact where phone like "440%"'
--, @TgtQry = 'Select * from AdventureWorksCopy.Person.Contact where phone like "440%"'
--, @SrcInstance = 'ASQL9'
--go
----------------------------------------------------------------------------------------
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Audit.GenerateIt'
GO
Create procedure Audit.GenerateIt
   @db sysname 
,  @schema sysname 
,  @tabListLike nvarchar(max)
,  @expirationDate datetime 
As
Begin  
  set nocount on 
  declare @Sql nvarchar(max)
  declare @SqlDyn nvarchar(max)
  Declare @Info nvarchar(max)

  Set @Info = 'Audit defined on ['+@db+'].['+@schema+'] for table names that match like '+@tabListLike 
  Exec yExecNLog.LogAndOrExec 
    @context = 'Audit.GenerateIt'
  , @Info = @Info

  Set @Sql = 
  '
  Use [<db>]
  Select T.OBJECT_id, @schema, ltrim(rtrim(T.name))
  From 
    YourSqlDba.yUtl.SplitParamInRows (@TabListLike) as A
    join 
    sys.tables T
    ON T.name like A.line Collate Latin1_general_ci_ai And 
       SCHEMA_NAME(T.schema_id) = @Schema Collate Latin1_general_ci_ai
  '
  Set @Sql = replace (@sql, '<db>', @db) 
  Create table #tabList (objID INT primary key clustered, schName sysname, TAB sysname)
  Insert into #tabList
  Exec sp_executeSql @Sql, N'@TabListLike nvarchar(max), @Schema sysname', @TabListLike, @Schema

  Declare @objId Int
  Declare @TAB sysname
  Select @objId = MIN(objId)-1 from #tablist
  While(1=1)
  Begin
    Select top 1
      @objId = objId
    , @TAB = TAB
    From #tabList
    Where objId > @objId
    If @@ROWCOUNT = 0 break

    Set @Sql = 
    '
    Use [<db>]
    If schema_id("yAudit_<Sch>") Is NULL exec("Create schema [yAudit_<Sch>]")
    If schema_id("yAudit_<Sch>_TxSeq") Is NULL exec("Create schema [yAudit_<Sch>_TxSeq]")
    '  
    Set @Sql = replace (@sql, '<db>', @db) 
    Set @Sql = replace (@sql, '<sch>', @schema) 
    Set @Sql = replace (@sql, '"', '''') 
    print @sql
    Exec(@sql)
    
    Set @Sql = 
    '
    Use [<db>]
    If object_id("[yAudit_<sch>].[<TAB>]") IS NOT NULL
      Drop Table [yAudit_<sch>].[<TAB>]
      
    If object_id("[yAudit_<sch>_TxSeq].[<TAB>]") IS NOT NULL
      Drop Table [yAudit_<sch>_TxSeq].[<TAB>]
    '   
    Set @Sql = replace (@sql, '<db>', @db) 
    Set @Sql = replace (@sql, '<sch>', @schema) 
    Set @Sql = replace (@sql, '<TAB>', @TAB) 
    Set @Sql = replace (@sql, '"', '''') 
    print @sql
    Exec(@sql)

    Declare @ColsRedefToAllowInsert Nvarchar(max)
    Set @Sql = 
    '
    Use [<db>]
      
    Select @ColsRedefToAllowInsert =
      (
      Select 
        convert
        (nvarchar(max), ", "+
         Case 
           When Is_Identity = 1 Then "convert(bigInt, 0) as ["+name+"]" 
           When type_name(system_type_id) in ("timestamp", "rowversion") Then "convert(varbinary(8), 0) as ["+name+"]" 
           Else "["+name+"]" 
         End
        ) as [text()]
      From sys.columns  
      Where object_id = object_id("[<sch>].[<TAB>]")
      Order by column_id
      For XML PATH("")
      )
    '  

    Set @Sql = replace (@sql, '<db>', @db) 
    Set @Sql = replace (@sql, '<sch>', @schema) 
    Set @Sql = replace (@sql, '<TAB>', @TAB) 
    Set @Sql = replace (@sql, '"', '''') 
    print @sql
    Exec sp_executeSql @Sql, N'@ColsRedefToAllowInsert Nvarchar(max) OUTPUT', @ColsRedefToAllowInsert Output

    Set @Sql = 
    '
    Use [<db>]
      
    Select distinct top 0
      convert(bigint, 0) as [y_TxSeq]
    , convert(nchar(1), " ") as [y_Op]
    , convert(nchar(1), " ") as [y_BeforeOrNew]
    , getdate() as [y_EvTime]
    , app_name() as [y_App]
    , host_name() as [y_Wks]
    , suser_sname() as [y_Who]
    , user_name() as [y_DbUser]
    <*>
    into [yAudit_<sch>].[<TAB>]
    From [<sch>].[<TAB>]
    
    Create table [yAudit_<sch>_TxSeq].[<TAB>] (seq bigInt identity, dummyInsert int)
    '  
    Set @Sql = replace (@sql, '<db>', @db) 
    Set @Sql = replace (@sql, '<sch>', @schema) 
    Set @Sql = replace (@sql, '<TAB>', @TAB) 
    Set @Sql = replace (@sql, '"', '''') 
    Set @Sql = REPLACE (@Sql, '<*>', @ColsRedefToAllowInsert) 
    print @sql
    Exec(@sql)

    Set @SqlDyn = 
    '
    Create trigger [<sch>].[<TAB>_yAudit] 
    ON [<sch>].[<TAB>]
    For insert, delete, update
    as
    Begin
      /*<expDate>:<TAB>_yAudit_expirationDate*/
      If @@rowcount = 0 return
      If Trigger_nestlevel()> 1 Return
      Set nocount on  
      Declare @op Nchar(1)
      select top 1 @op = "D" from deleted
      select top 1 @op = case when @op = "D" Then "U" Else "I" End from inserted
      
      Declare @txSeq BigInt
      begin tran IncBox
      save tran inc
      insert into [yAudit_<sch>_TxSeq].[<TAB>] (dummyInsert) values (0)
      Set @txSeq = @@identity
      rollback tran inc -- identity do not rollback
      commit tran IncBox
      
      ; With WhenHowWho as (Select  getdate() as EventTime, app_name() as Through, host_name() as FromWks, suser_sname() as Who, user_name() as DbUser)
      , BeforeValues as (Select @txSeq as TxSeq, @op as Op, "B" as BeforeOrNew, What.*, Tx.* From WhenHowWho as What cross join Deleted as tx)
      , NewValues as (Select @txSeq as TxSeq, @op as Op, "N" as BeforeOrNew, What.*, Tx.* From WhenHowWho as What cross join Inserted as tx)
      insert into [yAudit_<sch>].[<TAB>]
      Select * From BeforeValues
      union all
      Select * From NewValues
    End  
    '
    Set @SqlDyn = replace (@sqlDyn, '<sch>', @schema) 
    Set @SqlDyn = replace (@sqlDyn, '<TAB>', @TAB) 
    Set @SqlDyn = replace (@sqlDyn, '<expDate>', convert(nvarchar(8), @expirationDate,112) )
    Set @SqlDyn = replace (@sqlDyn, '"', '''') 
    
    Set @Sql =
    '
    Use [<db>]
    If object_id("[<sch>].[<TAB>_yAudit]") IS NOT NULL
      Drop trigger [<sch>].[<TAB>_yAudit];
    Exec sp_executeSql @SqlDyn
    '
    Set @Sql = replace (@sql, '<db>', @db) 
    Set @Sql = replace (@sql, '<sch>', @schema) 
    Set @Sql = replace (@sql, '<TAB>', @TAB) 
    Set @Sql = replace (@sql, '"', '''') 

    print '@SqlDyn='+nchar(10)+@sqlDyn 
    print '@Sql='+@sql
    Exec sp_executeSql @Sql, N'@sqlDyn nvarchar(max)', @SqlDyn

  End  -- While
  
End -- Audit.GenerateIt  
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Audit.SuspendIt'
GO
Create procedure Audit.SuspendIt
   @db sysname 
,  @schema sysname 
,  @tabListLike nvarchar(max)
As
Begin  
  set nocount on 
  declare @Sql nvarchar(max)
  Declare @Info nvarchar(max)
  Set @Info = 'Audit suspended on ['+@db+'].['+@schema+'] for table names that match like '+@tabListLike 
  Exec yExecNLog.LogAndOrExec 
    @context = 'Audit.SuspendIt'
  , @Info = @Info
 
  Set @Sql = 
  '
  Use [<db>]
  Select T.OBJECT_id, @schema, ltrim(rtrim(T.name))
  From 
    YourSqlDba.yUtl.SplitParamInRows (@TabListLike) as A
    join 
    sys.tables T
    ON T.name like A.line Collate Latin1_general_ci_ai And 
       SCHEMA_NAME(T.schema_id) = @Schema Collate Latin1_general_ci_ai
  '
  Set @Sql = replace (@sql, '<db>', @db) 
  Create table #tabList (objID INT primary key clustered, schName sysname, TAB sysname)
  Insert into #tabList
  Exec sp_executeSql @Sql, N'@TabListLike nvarchar(max), @Schema sysname', @TabListLike, @Schema

  Declare @objId Int
  Declare @TAB sysname
  Select @objId = MIN(objId)-1 from #tablist
  While(1=1)
  Begin
    Select top 1
      @objId = objId
    , @TAB = TAB
    From #tabList
    Where objId > @objId
    If @@ROWCOUNT = 0 break

    Set @Sql = 
    '
    Use [<db>]
    alter table [<sch>].[<TAB>] disable trigger [<TAB>_yAudit] 
    '
    Set @Sql = replace (@Sql, '<db>', @db) 
    Set @Sql = replace (@Sql, '<sch>', @schema) 
    Set @Sql = replace (@Sql, '<TAB>', @TAB) 
    Set @Sql = replace (@Sql, '"', '''') 
    print @sql
    Exec sp_executeSql @Sql
    
  End  -- While
  
End -- Audit.SuspendIt  
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Audit.ReactivateIt'
GO
Create procedure Audit.ReactivateIt
   @db sysname 
,  @schema sysname 
,  @tabListLike nvarchar(max)
As
Begin  
  set nocount on 
  declare @Sql nvarchar(max)
  declare @SqlDyn nvarchar(max)
  Declare @Info nvarchar(max)
  Set @Info = 'Audit reactivated on ['+@db+'].['+@schema+'] for table names that match like '+@tabListLike 
  Exec yExecNLog.LogAndOrExec 
    @context = 'Audit.ReactivateIt'
  , @Info = @Info

  Set @Sql = 
  '
  Use [<db>]
  Select T.OBJECT_id, @schema, ltrim(rtrim(T.name))
  From 
    YourSqlDba.yUtl.SplitParamInRows (@TabListLike) as A
    join 
    sys.tables T
    ON T.name like A.line Collate Latin1_general_ci_ai And 
       SCHEMA_NAME(T.schema_id) = @Schema Collate Latin1_general_ci_ai
  '
  Set @Sql = replace (@sql, '<db>', @db) 
  Create table #tabList (objID INT primary key clustered, schName sysname, TAB sysname)
  Insert into #tabList
  Exec sp_executeSql @Sql, N'@TabListLike nvarchar(max), @Schema sysname', @TabListLike, @Schema
  select * from #tablist

  Declare @objId Int
  Declare @TAB sysname
  Select @objId = MIN(objId)-1 from #tablist
  While(1=1)
  Begin
    Select top 1
      @objId = objId
    , @TAB = TAB
    From #tabList
    Where objId > @objId
    If @@ROWCOUNT = 0 break

    Set @Sql = 
    '
    Use [<db>]
    alter table [<sch>].[<TAB>] enable trigger [<TAB>_yAudit] 
    '
    Set @Sql = replace (@Sql, '<db>', @db) 
    Set @Sql = replace (@Sql, '<sch>', @schema) 
    Set @Sql = replace (@Sql, '<TAB>', @TAB) 
    print @sql
    Exec sp_executeSql @sql
    
  End  -- While
  
End -- Audit.ReactivateIt  
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Audit.RemoveIt'
GO
Create procedure Audit.RemoveIt
   @db sysname 
,  @schema sysname 
,  @tabListLike nvarchar(max)
,  @jobNo Int = NULL
As
Begin  
  set nocount on 
  declare @Sql nvarchar(max)
  Declare @Info nvarchar(max)
  Set @Info = 'Audit removed on ['+@db+'].['+@schema+'] for table names that match like '+@tabListLike 
  Exec yExecNLog.LogAndOrExec 
    @context = 'Audit.RemoveIt'
  , @Info = @Info
  , @jobNo = @jobNo
 
  Set @Sql = 
  '
  Use [<db>]
  Select T.OBJECT_id, @schema, ltrim(rtrim(T.name))
  From 
    YourSqlDba.yUtl.SplitParamInRows (@TabListLike) as A
    join 
    sys.tables T
    ON T.name like A.line Collate Latin1_general_ci_ai And 
       SCHEMA_NAME(T.schema_id) = @Schema Collate Latin1_general_ci_ai
  '
  Set @Sql = replace (@sql, '<db>', @db) 
  Create table #tabList (objID INT primary key clustered, schName sysname, TAB sysname)
  Insert into #tabList
  Exec sp_executeSql @Sql, N'@TabListLike nvarchar(max), @Schema sysname', @TabListLike, @Schema

  Declare @objId Int
  Declare @TAB sysname
  Select @objId = MIN(objId)-1 from #tablist
  While(1=1)
  Begin
    Select top 1
      @objId = objId
    , @TAB = TAB
    From #tabList
    Where objId > @objId
    If @@ROWCOUNT = 0 break

    Set @Sql = 
    '
    Use [<db>]
    If object_id("[<sch>].[<TAB>_yAudit]") IS NOT NULL
      Drop trigger [<sch>].[<TAB>_yAudit] 
    If object_id("yAudit_<sch>.<TAB>") IS NOT NULL
      Drop table [yAudit_<sch>].[<TAB>]
    If object_id("yAudit_<sch>_TxSeq.<TAB>") IS NOT NULL
      Drop table [yAudit_<sch>_TxSeq].[<TAB>]
    '
    Set @Sql = replace (@Sql, '<db>', @db) 
    Set @Sql = replace (@Sql, '<sch>', @schema) 
    Set @Sql = replace (@Sql, '<TAB>', @TAB) 
    Set @Sql = replace (@Sql, '"', '''') 
    print @sql
    Exec sp_executeSql @Sql
    
  End  -- While
  
End -- Audit.RemoveIt  
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Audit.ProcessExpiredDataAudits'
GO
Create procedure Audit.ProcessExpiredDataAudits 
  @db sysname
, @jobNo Int = NULL
as
Begin  
  Declare 
    @schema sysname 
  , @tabListLike nvarchar(max)  
  , @sql nvarchar(max)
  
  create table #triggerMatch (sch sysname, TAB sysname, primary  key clustered (sch, TAB))
  Set @sql =
  '
  use [<db>]
  ;With TrigDetails
  as
  (
  Select 
    TR.name as TRG
  , TR.object_id
  , Object_name(TR.parent_id) as TAB
  , schema_name(convert(int, objectpropertyex(TR.parent_id, "schemaId"))) as SCH
  From 
    sys.triggers TR
  )
  , TabWithAuditTriggerExpired
  as
  (
  Select 
    TRG
  , Stuff( Stuff(M.definition, 1, charindex(TAB+"_yAudit_expirationDate", M.definition) -10, ""), 9, len(M.definition), "") as ExpDate
  , TAB
  , SCH
  From  
    TrigDetails TR
    Join 
    sys.sql_modules M
    On M.object_id = TR.object_id
  Where 
      TAB+"_yAudit" = TRG 
      -- expiration date is located as a comment into the trigger code
  And M.definition like "%"+TAB+"_yAudit_expirationDate%"   
  )
  Select SCH, TAB
  From TabWithAuditTriggerExpired
  Where getdate() > convert(datetime, expDate, 112)
  '  

  Set @sql = replace (@sql, '<db>', @db)
  Set @sql = replace (@sql, '"', '''')
  
  Insert into #triggerMatch (sch, TAB)
  Exec sp_executeSql @sql

  If @@ROWCOUNT > 0  
  Begin
    Declare @Info nvarchar(max)
    Set @Info = 'Start removing audit expired on ['+@db+'] '
    Exec yExecNLog.LogAndOrExec 
      @context = 'Audit.ProcessExpiredDataAudits'
    , @Info = @Info
    , @jobNo = @jobNo
  End
  
  While (1=1)
  Begin
    Select top 1 @schema = sch
    From #triggerMatch
    
    If @@ROWCOUNT = 0 
      Break
    
    Select 
      @tabListLike =
      (
      Select     
        CONVERT(nvarchar(max), '||') + TAB as [text()]
      From #triggerMatch 
      Where sch = @schema   
      Order by TAB
      For XML PATH('')
      )

    Set @tabListLike = REPLACE(@tabListLike , '||', yUtl.UnicodeCrLf()) 
    Exec Audit.RemoveIt @db = @db, @schema = @schema, @tabListLike = @tabListLike, @jobNo = @JobNo
     
    Delete -- remove processed schema
    From #triggerMatch 
    Where sch = @schema

  End  
  
End -- Audit.ProcessExpiredDataAudits  
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Audit.ProcessDataAuditsCleanup'
GO
Create procedure Audit.ProcessDataAuditsCleanup 
  @db sysname
, @jobNo Int = NULL
as
Begin  
  Declare 
    @Sql nvarchar(max)

  Declare @Info nvarchar(max)
  
  If @jobNo is NOT NULL -- may be call from ProcessDataAuditsCleanupForAllDb
  Begin
    Set @Info = 'Audit traces cleanup on ['+@db+'] to preserve space'
    Exec yExecNLog.LogAndOrExec 
      @context = 'Audit.ProcessDataAuditsCleanup'
    , @Info = @Info
    , @jobNo = @jobNo
  End

  Set @Sql =
  '
  use [<db>]

  declare @trunc table (seq int primary key clustered, sch sysname, tb sysname)

  ;With SelectedTrigger
  as
  (
  Select 
    schema_name(convert(int, objectpropertyex(TR.parent_id, "schemaId"))) as sch
  , TR.name as trg
  , Object_name(TR.parent_id) as Tb
  From 
    sys.triggers TR
  )  
  Insert into @trunc (seq, sch, tb)
  Select
    ROW_NUMBER() over(order by sch, tb) as Seq
  , sch
  , Tb
  From
    SelectedTrigger
  Where trg = tb + "_yAudit" 
 
  Declare 
    @sch sysname 
  , @tb sysname
  , @seq int
  , @sql nvarchar(max)

  Set @seq = 0
  While (1=1)
  Begin

    Select top 1 @seq = seq, @sch = sch,  @tb = tb
    From @trunc
    Where 
      seq > @seq
    Order by seq
    
    If @@ROWCOUNT = 0 
      Break
    
    Set @Sql = "Truncate table [yAudit_<sch>].[<tb>]"
    Set @Sql = REPLACE(@sql, "<sch>", @sch)
    Set @Sql = REPLACE(@sql, "<tb>", @tb)
    Exec sp_executeSql @Sql

  End -- While
  '
  Set @sql = replace (@sql, '<db>', @db)
  Set @sql = replace (@sql, '"', '''')

  Begin Try  
    Exec sp_executeSql @sql
  End Try
  Begin Catch
    Exec yExecNLog.LogAndOrExec @context='Audit.ProcessDataAuditsCleanup', @err='?', @JobNo = @jobNo
  End Catch
    
End -- Audit.ProcessDataAuditsCleanup  
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Audit.ProcessDataAuditsCleanupForAllDb'
GO
Create proc Audit.ProcessDataAuditsCleanupForAllDb
as
Begin
  set nocount on 
  DECLARE @RC int
  DECLARE @name sysname

  declare @db TABLE (name sysname primary Key)
  declare @jobNo int
  
  Insert into @db
  select name from sys.databases

  set @name = ''
  While (1=1)
  Begin 
    Select top 1 @name = name from @db where name > @name order by name 
    If @@ROWCOUNT = 0 break
    
    If DATABASEPROPERTYEX(@Name, 'Updateability') <> N'READ_WRITE'  
      Continue

    print @name
    Exec Audit.ProcessExpiredDataAudits @name, @jobNo
    Exec Audit.ProcessDataAuditsCleanup @name, @jobNo
  End
  
End -- Audit.ProcessDataAuditsCleanupForAllDb 
GO

-- ------------------------------------------------------------------------------
-- Function to get step command launched by maintenance job (when it is the case)
-- and present it in Html
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yExecNLog.FormatStepIntoHtml'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create function yExecNLog.FormatStepIntoHtml
(
  @jobNo Int
)
returns nvarchar(max)
as
Begin
  Declare @crLf nvarchar(4) Set @crlf = yUtl.UnicodeCrLf()
  Declare @JobStepCmd nvarchar(max)
  Declare @jobId UniqueIdentifier
  Declare @stepId Int
  
  Set @jobId = NULL
  Set @stepId = NULL
  Select @jobId = JobId, @stepId = stepId
  From  YourSQLDba.Maint.JobHistory
  Where jobNo = @jobNo

  Select @JobStepCmd = isnull(command, '')
  From Msdb.dbo.sysjobsteps
  Where job_id = @jobId 
    And Step_id = @stepId

  If @jobStepCmd = '' Or @jobStepCmd Is NULL
    Return ('')

  -- normalize use of crlf 
  Set @JobStepCmd = replace (@JobStepCmd, @crLf, '<br>')
  Set @JobStepCmd = replace (@JobStepCmd, '<br>', '<br>' + @crLf)

  Declare @msg nvarchar(max)
  Set @msg =
  '
  <br>
  <font size="3"><b>Command lauched by SQL Server Agent</b></font><br>
  <br>
  <table width="100%" border=1 cellspacing=0 cellpadding=5 style="background:#CCCCCC;border-collapse:collapse;border:none">
    <tr>
      <td width="100%" valign=top style="border:solid windowtext 1.0pt">
        <font face="Courier New" size="2">
        <span style="color:navy">
        <@JobStepCmd>
        </span></font>
      </td>
    </tr>
  </table>
  '

  Set @msg = replace(@msg, '<@JobStepCmd>', @JobStepCmd)
  Set @msg = replace(@msg, '"', '''')

  Return (@msg)

End -- yExecNLog.FormatStepIntoHtml
GO

-- ------------------------------------------------------------------------------
-- Procedure which send exec report and errors report
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.SendExecReports'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc yMaint.SendExecReports
  @email_Address nvarchar(200)
, @command nvarchar(200)  -- Help to select maintenance emails format
, @MaintJobName nvarchar(200)
, @StartOfMaint datetime
, @JobNo Int
, @SendOnErrorOnly int
as
Begin
  Declare @crLf nvarchar(4) Set @crlf = yUtl.UnicodeCrLf()
  Declare @JobStart nvarchar(max)
  Declare @JobEnd nvarchar(max)
  Declare @CompleteSql nvarchar(max)
  Declare @reportSource nvarchar(max)
  Declare @subject nvarchar(max)
  Declare @result nvarchar(max)
  Declare @shortResultMess nvarchar(max)
  Declare @versionYourSQLDba nvarchar(255)
  Declare @Error bit
  Declare @mailPriority nvarchar(20)
  Declare @JobName nvarchar(max)
  Declare @CommandTextInHtml nvarchar(max) Set @CommandTextInHtml = 'A'
  Declare @sqlAgentMsg nvarchar(max)
  
  Select @versionYourSQLDba = F.msg From Install.VersionInfo() As F
  
  Declare @jobId UniqueIdentifier
  Declare @stepId Int
  Set @jobId = NULL
  Select 
    @jobId = JobId
  , @JobName = isnull(JobName, '')
  From  YourSQLDba.Maint.JobHistory
  Where jobNo = @jobNo

  --Select @JobName = isnull(name, '')
  --From Msdb.dbo.sysjobs
  --Where job_id = @jobId 

  If @jobId = convert(uniqueidentifier, '00000000-0000-0000-0000-000000000000')   
  Begin
    -- The procedure as been executed outside of SQL Server Agent
    set @reportSource = 'Command:'
  End
  Else
  Begin
    set @reportSource = 'SQL Server Agent job:'
  End

  If @JobName = ''
  Begin
    Set @JobName = 'Manual Maintenance Job'
  End
  
  -- handling job report
  Set @mailPriority = 'Normal'
  Set @Error = 0
  
  Exec yExecNLog.LogAndOrExec 
    @context = 'Sending job report'
  , @JobNo = @JobNo

  Set @CompleteSql = 
  N' 
  <body style="font-family:verdana;font-size:9pt">  
  <font size="3">
    <b>Maintenance report </b>
  </font>
  <br>
  <br>
  <table border="0" CELLPADDING="5" style="font-size:9pt">
    <tr>
      <td style="padding-right:10px">
        Server: 
      </td>
      <td>
        <ServerInstance>
      </td>
    </tr>
    <tr>
      <td style="padding-right:10px">
        <reportSource>  
      </td>
      <td>
        <JobNameSource>
      </td>
    </tr>
    <tr>
      <td style="padding-right:10px">
        Start, end: 
      </td>
      <td>
        <JobStart>, &nbsp;&nbsp;<JobEnd>
      </td>
    </tr>
    <tr>
      <td style="padding-right:10px">
        Result:  
      </td>
      <td>
        <ShortResultMess>
      </td>
    </tr>
  </Table>
  <br>
  <result>
  <br>
  <br>
  To list all maintenance commands ran by the maintenance process 
  <br>
  execute the following command in a query windows connected to the 
  <br>
  SQL Server instance that ran the maintenance.
  <br>
  <br>
  <b>Exec YourSQLDba.Maint.ShowHistory @JobNo = <JobNo>, @DispLimit = 1</b> 
  <br>
  <br>
  <@CommandTextInHtml>
  ' +
  yExecNLog.FormatStepIntoHtml (@jobNo)
  +
  N'
  <br>
  <br>
  <font color="#777777"><VersionYourSQLDba></font>
  <br>
  <br>
  </body>  
  '
     
  Set @CompleteSql = replace(@CompleteSql, '<reportSource>', @reportSource)
  
  If Exists
     (
     Select *
     From Maint.JobHistoryDetails 
     Where JobNo = @JobNo 
       And yExecNLog.ErrorPresentInAction(action) = 1
       And cmdStartTime > @StartOfMaint
     )
  Begin
    Set @Error = 1
    Set @mailPriority = 'High'
    Set @shortResultMess = 
    N'
    <font color="red" size="3">
      <b>
        Error detected by maintenance process
      </b>
    </font>
    '
    Set @result = 
    N'
    To list the errors, copy & paste the following command in a query window<br>
    connected to the SQL Server instance that ran the maintenance.
    <br>
    <br>
    <b>Exec YourSQLDba.Maint.ShowHistoryErrors <JobNo></b>
    <br>
    <br>
    <br>
    To bring back quickly any databases online from offline, run this command:
    <br>
    <br>
    <b>Exec YourSQLDba.Maint.BringBackOnlineAllOfflineDb</b>
    <br>
    '
    Raiserror 
    (
    'Some errors occurred in maintenance. Copy and run this command in a query window to see them: %s %d;  
                                                            
                                                            
                                                            -- 
                                                          --
                                                          --
    ',11,1, 
    'EXEC YOURSQLDBA.MAINT.SHOWHISTORYERRORS',
    @jobNo
    )
  End
  Else
  Begin
    Set @shortResultMess = 
    N'
    <font size="3">
      <b>
        Maintenance succeeded
      </b>
    </font>
    '
    Set @result = 
    N'  
    '
  End

  Select 
    @JobStart = isnull(convert(nvarchar(30), JobStart, 120),'')
  , @JobEnd = isnull(convert(nvarchar(30), JobEnd, 120),'')
  From Maint.JobHistory 
  Where JobNo = @JobNo 

  Set @CompleteSql = replace(@CompleteSql, '<JobStart>', @JobStart)
  Set @CompleteSql = replace(@CompleteSql, '<JobEnd>', @JobEnd)
  Set @CompleteSql = replace(@CompleteSql, '<shortResultMess>', @shortResultMess)
  Set @CompleteSql = replace(@CompleteSql, '<result>', @result)
  Set @CompleteSql = replace(@CompleteSql, '"', '''')
  Set @CompleteSql = replace(@CompleteSql, '<JobNo>', @JobNo)
  Set @CompleteSql = replace(@CompleteSql, '<VersionYourSQLDba>', @versionYourSQLDba)

  Declare @ServerInstance sysname
  Set @ServerInstance = convert(sysname, serverproperty('ServerName'))

  Set @CompleteSql = replace(@CompleteSql, '<ServerInstance>', @ServerInstance)

  If @jobId = convert(uniqueidentifier, '00000000-0000-0000-0000-000000000000')   
  Begin
    -- The procedure has been executed outside of SQL Server Agent
    --If @MaintJobName like 'SaveDbOnNewFileSet%' 
    If @command like 'SaveDbOnNewFileSet%' 
    Begin
      Set @subject = 
                @ServerInstance 
              + ',   ' 
              + @reportSource
              + '  ' 
              + @MaintJobName  
      Set @CompleteSql = replace(@CompleteSql, '<JobNameSource>', @command)
    End
    Else
    If @command like 'DeleteOldBackups%' 
    Begin
      Set @subject =  
                @ServerInstance
              + ',   ' 
              + @reportSource
              + ' '
              + @command
      Set @CompleteSql = replace(@CompleteSql, '<JobNameSource>', @command)
    End
    Else
    If @command like 'YourSQLDba_DoMaint%' 
     Begin
      Set @subject =  
                @ServerInstance
              + ',   ' 
              + @reportSource
              + ' '
              + @command
      Set @CompleteSql = replace(@CompleteSql, '<JobNameSource>', @command)
    End
  
    exec YourSqlDba.yExecNLog.CommandTextIntoHtml @CommandTextInHtml = @CommandTextInHtml output

    Set @CompleteSql = replace(@CompleteSql, '<@CommandTextInHtml>', isnull(@CommandTextInHtml,''))
  End
  Else
  Begin -- The procedure has been executed from SQL Server Agent
    Set @subject =  
              @ServerInstance
            + ',   ' 
            + @reportSource
            + ' '
            + @JobName
    Set @CompleteSql = replace(@CompleteSql, '<JobNameSource>', @JobName)
    Set @CompleteSql = replace(@CompleteSql, '<parameters>', '') -- we don't need the parameters
    Set @CompleteSql = replace(@CompleteSql, '<@CommandTextInHtml>', '')
  End
  
  If @SendOnErrorOnly = 1 And @Error = 0
    Return

  If @Error = 1 Set @subject = 'MAINTENANCE ERROR: '+@subject

  Set @subject = yInstall.DoubleLastSpaceInFirst150Colums(@subject)
  Set @subject = yInstall.DoubleLastSpaceInFirst78Colums(@subject)

  --print '--------------------  Sent message ------------------------------' 
  --print @subject
  --print '-------------------------------------------------------------------' 

  EXEC  Msdb.dbo.sp_send_dbmail
    @profile_name = 'YourSQLDba_EmailProfile'
  , @recipients = @email_Address
  , @importance = @mailPriority  
  , @subject = @subject
  , @body = @CompleteSql
  , @body_format = 'HTML'

  Print 'Message sent to '+@email_Address
  Print 'Subject: ' + @subject
  --print '--------------------  Sent message ------------------------------' 
  --print @CompleteSql 
  --print '-------------------------------------------------------------------' 

End -- yMaint.SendExecReports
GO

-- ------------------------------------------------------------------------------
-- Procedure that performs the CheckFullRecoveryModel policy.  Database not in FULL Recovery 
-- model will generate an error of the maintenance.  It is possible to exclude
-- this check for particular databases with the parameter @ExcDbFromPolicy_CheckFullRecoveryModel
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.CheckFullRecoveryModelPolicy'
GO
create proc yMaint.CheckFullRecoveryModelPolicy
  @jobNo Int
, @IncDb nVARCHAR(max)
, @ExcDb nVARCHAR(max)
, @ExcDbFromPolicy_CheckFullRecoveryModel nvarchar(max)
as
Begin
  Declare @dblist nvarchar(max)
  Declare @context nvarchar(max)
  Declare @DbCount int

  Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.CheckFullRecoveryModelPolicy'
    , @Info = 'Check Recovery policy'
    , @JobNo = @jobNo

  -- Add the exclusions of @ExcDbFromPolicy_CheckFullRecoveryModel to the selection
  Set @ExcDb = @ExcDb + CHAR(10) + @ExcDbFromPolicy_CheckFullRecoveryModel
  
  Set @dblist = ''
  
  Select @dblist = @dblist + ',' + x.DbName 
  From 
    sys.databases db
    
    join
    yUtl.YourSQLDba_ApplyFilterDb(@IncDb, @ExcDb) x
    on db.name = x.DbName collate database_default 
    
  Where x.FullRecoveryMode <> 1
    And db.source_database_id is Null
    AND x.DbName Not In ('master', 'YourSQLDba', 'msdb', 'model')
    AND x.DbName Not Like 'ReportServer%TempDB'
    AND x.DbName Not Like 'YourSQLDba%'
    AND DatabasepropertyEx(DbName, 'Status') = 'Online' -- To Avoid db that can't be processed
  
  Set @dbcount = @@ROWCOUNT 

  Set @dblist = Stuff( @dblist, 1, 1, '')   

  If @dbcount > 0
  Begin
    declare @err nvarchar(max) 
    Set @err = 'Violation of Recovery model policy for db :'+@dbList
    Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.CheckFullRecoveryModelPolicy'
    , @YourSqlDbaNo = '006'  
    , @err = @err 
    , @Info = 'If you are sure you want those databases in SIMPLE recovery model you can use the «@ExcDbFromPolicy_CheckFullRecoveryModel» parameter of the «YourSQLDba_DoMaint» to exclude databases from the check'
    , @JobNo = @JobNo
  End
    
End -- yMaint.CheckFullRecoveryModelPolicy
GO

-- ------------------------------------------------------------------------------
-- Procedure who perform log shrink
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.ShrinkLog'
GO
create proc yMaint.ShrinkLog
  @Db nvarchar(128)
, @JobNo Int
, @MustLogBackupToShrink int output
as
Begin
  Declare @DatSize Int
  Declare @LogSize Int 
  Declare @infoPremLog nvarchar(1000)
  Declare @Sql nvarchar(max)
  Declare @newSize Int
  Set @MustLogBackupToShrink = 0
  
  -- Test if there is nothing that prevent log truncation and shrink 
  -- The goal is to avoid causing errors to other transactions or replication/mirroring/backup processes.
  -- because of concurrent DBCC ShrinkFile
  -- In SQL2012 SP2 it happens frequently that a status LOG_BACKUP is there when there is not current log backup
  If exists (Select * from sys.databases where name = @Db And log_reuse_wait not in (0,2))
  Begin
    -- Wait for 10 sec and try again
    WAITFOR DELAY '00:00:10';

    If exists (Select * from sys.databases where name = @Db And log_reuse_wait not in (0,2))
    BEGIN
      Print 'Log shrinking delayed for '+@Db
      Return ----    ******* Exit here
    END
  End   

  Set @sql =
  '
  With FileInfo as
  (
  Select 
    -- generate a sequence in which the lowest values match bigger file 
    row_number() over (order by df.type_desc, df.size desc) as Seq 
  , fg.name as fGroup
  , fg.is_default
  , ISNULL(df.size, 0) as Size
  , df.name
  , df.physical_name
  , df.type_desc
  From 
    sys.master_files df 
    left join
    [<DbName>].sys.filegroups fg
    On fg.data_space_id = df.data_space_id
  where df.database_id = db_id("<DbName>")
  ) 
  Select 
    -- compute a pseudo data size that is going to be used to compute a log size that 
    -- is a ratio of this data size. Primary file or default file group are the basis 
    -- of this log size ratio computation. Other files are assumed to be possibly 
    -- dedicated to blob storage, and usually blog storage represent less transactions.
    -- So less log space is requiered for blob storage that OLTP files.
    @DatSize = 
    Sum(Case 
          -- we just take in this computation the primary file plus default filegroup
          -- we make the assumption that other files are something dedicated for blob storage
          -- we know that this is not an absolute
          When fGroup = "primary" or is_default = 1
          Then Size  -- ordinary data
          Else case -- assume that other files content move less and require less log file
                 when fGroup is not null -- when this is not the log 
                 then Size / 10 -- 1/10 reduce weight of data size to compute smaller log ratio size 
                 Else 0
               End 
        End) 
  , @logSize = Sum(Case When type_desc = "LOG" Then Size Else 0 End) 
  -- MIN is used to discriminate the most interesting log to resize
  , @infoPremLog = Min(Case When type_desc = "LOG" 
                            Then Str(Seq, 3)+ convert(nchar(100), name) +physical_name 
                            Else NULL End) 
  From 
    FileInfo
  '
  Set @sql = replace(@sql, '"', '''')
  Set @sql = replace(@sql, '<DbName>', @Db)
  Set @sql = yExecNLog.Unindent_TSQL(@sql)
  --print @sql
  
  Exec sp_executeSql 
    @sql
  , N'@DatSize Int Output, @LogSize Int output, @infoPremLog nvarchar(1000) output'
  , @DatSize Output
  , @LogSize output
  , @infoPremLog output

  -- manage only one log at the time usually the biggest. Usually there is only on big log file for a database
  -- if log size exceed % from the size of database data, it is shrinked
  
  -- select (1024*1024) / (8192) -- compute number of 8k in 1 meg) = 128
  
  Set @datSize = @datSize / 128 -- translate number of page in meg
  Set @logSize = @logSize /128 -- translate number of page in meg
  
  print 'Actual data size ' + convert(nvarchar(30), @datSize)+'Mb'
  print 'Actual log size ' + convert(nvarchar(30), @logSize)+'Mb'
  
  If (@logSize > @DatSize * 0.20) And -- log size > 20% data size
     (@logSize > 10) And -- log size > 10 meg
     (@DatSize * 0.20 > 10) -- when datasize reduce to 20%, it must be greater than 10 meg
  Begin 
    -- new log size is reduced to one fifth of datafile
    Set @newSize = @DatSize * 0.20 
      
    Print 'Log shrink in process for '+@Db
    
    Set @sql =
    '
    --  ' + replicate ('=',80) + '
    -- Shrink of log file <nomFichierLog>
    USE [<DbName>]
    DBCC SHRINKFILE (N"<name>", <targetSize>) with no_infomsgs           
    --  ' + replicate ('=',80) 
    Set @sql = replace(@sql, '"', '''')
    Set @sql = replace(@sql, '<DbName>', @Db)
    Set @sql = replace(@sql, '<name>', rtrim(SUBSTRING(@infoPremLog, 4, 100)))
    Set @sql = replace(@sql, '<targetSize>', Str(@newSize,10))
    Set @sql = replace(@sql, '<nomFichierLog>', SUBSTRING(@infoPremLog, 104, 1000))

    Exec yExecNLog.LogAndOrExec 
        @context = 'yMaint.ShrinkLog'
      , @Info = 'Log Shrink'
      , @sql = @sql
      , @JobNo = @JobNo

    Set @sql =
    '
    Select @logSize = (size / 128)
    From [<DbName>].sys.database_files df
    WHERE name = N"<name>"
    '

    Set @sql = replace(@sql, '"', '''')
    Set @sql = replace(@sql, '<DbName>', @Db)
    Set @sql = replace(@sql, '<name>', rtrim(SUBSTRING(@infoPremLog, 4, 100)))
    Set @sql = yExecNLog.Unindent_TSQL(@sql)
    print @sql
    Exec sp_executeSql 
      @sql
    , N'@logSize Int Output'
    , @logSize Output

    -- if log doesn't shrink, shrink needs to be done more than once, with log backups in between
    -- a return value instruct the caller to do so
    If (Abs(@newSize - @logSize) / @newSize) > 0.01
      Set @MustLogBackupToShrink = 1    

  End  
End -- yMaint.ShrinkLog
GO
-- ------------------------------------------------------------------------------
-- Utility proc to bring back all Db offline in normal mode
-- in case YourSqlDba put them offline because of a disconnected drive
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.BringBackOnlineAllOfflineDb'
GO
CREATE proc Maint.BringBackOnlineAllOfflineDb
as
Begin
  Declare @sql nvarchar(max)
  
  Select name, cast (databasepropertyex(name, 'status') as Sysname) as Status into #Db 
  From sys.databases 
  Where databasepropertyex(name, 'status') = 'OFFLINE'

  Declare @n sysname, @status sysname
  While exists (select * from #Db)
  Begin
    Select top 1 @n = name, @status = Status from #Db

    Set @sql = 
    '
    Alter database [<DbName>] Set online
    Alter database [<DbName>] Set MULTI_USER
    '
    Set @sql = yExecNLog.Unindent_TSQL(@sql)
    Exec yExecNLog.QryReplace @sql output, '<DbName>', @n
    Exec (@sql)
    print @sql
    Delete from #Db where name = @n
  End
End -- Maint.BringBackOnlineAllOfflineDb
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.LogCleanup'
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
-----------------------------------------------------------------------------
-- yMaint.LogCleanup (for entries older than 30 days)
-- Mail logs
-- Backup history logs
-- Job history
-- Cycle SQL Server error log
-----------------------------------------------------------------------------
create proc yMaint.LogCleanup 
  @jobNo Int
as
Begin
  declare @d nvarchar(8)
  declare @lockResult int
  declare @sql nvarchar(max)

  Begin try

  Set @sql = 'Exec msdb.dbo.sysmail_delete_log_sp @logged_before = "<d>";'
  Set @sql = replace (@sql, '<d>', convert(nvarchar(8), dateadd(dd, -30, getdate()), 112))
  Set @sql = replace (@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @context = 'yMaint.LogCleanup'
  , @info = 'Cleanup log entries older than 30 days, begins with mail'
  , @sql = @sql
  , @JobNo = @JobNo
  
  Set @sql = 'EXECUTE msdb.dbo.sysmail_delete_mailitems_sp  @sent_before = "<d>";'
  Set @sql = replace (@sql, '<d>', convert(nvarchar(8), dateadd(dd, -30, getdate()), 112))
  Set @sql = replace (@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @context = 'yMaint.LogCleanup'
  , @info = 'Cleanup log entries older than 30 days, for mailitems'
  , @sql = @sql
  , @JobNo = @JobNo

  -- clean backup history
  Set @sql = 'exec  Msdb.dbo.sp_delete_backuphistory   @oldest_date = "<d>" '
  Set @sql = replace (@sql, '<d>', convert(nvarchar(8), dateadd(dd, -30, getdate()), 112))
  Set @sql = replace (@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @context = 'yMaint.LogCleanup'
  , @info = 'Cleanup log entries older than 30 days, for backup history'
  , @sql = @sql
  , @JobNo = @JobNo
  
  -- clean sql agent job history
  Set @sql = 'EXECUTE  Msdb.dbo.sp_purge_jobhistory  @oldest_date = "<d>"'
  Set @sql = replace (@sql, '<d>', convert(nvarchar(8), dateadd(dd, -30, getdate()), 112))
  Set @sql = replace (@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @context = 'yMaint.LogCleanup'
  , @info = 'Cleanup log entries older than 30 days, for job history'
  , @sql = @sql
  , @JobNo = @JobNo
  
  -- clean job maintenance job history (SQL Server own maintenance)
  Set @sql = 'EXECUTE  Msdb.dbo.sp_maintplan_delete_log null,null,"<d>"'
  Set @sql = replace (@sql, '<d>', convert(nvarchar(8), dateadd(dd, -30, getdate()), 112))
  Set @sql = replace (@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @context = 'yMaint.LogCleanup'
  , @info = 'Cleanup log entries older than 30 days, for SQL Server job maintenace plans'
  , @sql = @sql
  , @JobNo = @JobNo
  
  -- archive current log, and start a new one
  Set @sql = 'Execute sp_cycle_errorlog'
  Set @sql = replace (@sql, '<d>', convert(nvarchar(8), dateadd(dd, -30, getdate()), 112))
  Set @sql = replace (@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @context = 'yMaint.LogCleanup'
  , @info = 'Recycle Sql Server error log, start a new one'
  , @sql = @sql
  , @JobNo = @JobNo

  Delete H
  From 
    (
    Select distinct JobNo -- 
    From  Maint.JobHistory
    Where JobStart < dateadd(dd, -30, getdate())
    ) as T
    join
    Maint.JobHistory H  
    On H.JobNo = T.JobNo

  End try
  Begin catch
    Exec yExecNLog.LogAndOrExec 
        @context = 'yMaint.LogCleanup'
      , @Info = 'Error caught in proc'  
      , @err = '?'
      , @JobNo = @JobNo
  End Catch

End -- yMaint.LogCleanup
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.IntegrityTesting'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
----------------------------------------------------------------------------------------
-- yMaint.IntegrityTesting
-- Process integrity testing using 
CREATE proc yMaint.IntegrityTesting 
  @jobNo Int
, @SpreadCheckDb Int
as
Begin
  declare @cmptlevel Int
  declare @dbName nvarchar(512)
  declare @sql nvarchar(max)
  declare @lockResult int
  declare @errorN int
  declare @seqCheckNow  Int
  declare @doFullCheckDb Int

  Set @DbName = ''
  Update Maint.JobSeqCheckDb 
      Set @seqCheckNow = (seq + 1) % @SpreadCheckDb, seq = @seqCheckNow 

  ;With 
    DbSize as
    (
    SELECT Db.dbname, cmptlevel, sizedb = CAST(SUM(size) * 8. / 1024 / 1024 AS DECIMAL(8,2))
    FROM 
      #db as Db
      JOIN 
      sys.master_files as MF  WITH(NOWAIT)
      ON MF.database_id = Db_id(Db.DbName)
    GROUP BY dbname, cmptlevel
    )
  , MakeDbLeagueBySize as
    (
    Select *, ntile(@SpreadCheckDb) Over(Order by sizedb) as League
    From 
      DbSize
    )
  , AddRankingInEachLeague as 
    (
    Select *, dense_rank() Over(Partition by League Order by SizeDb) as RankingInLeague
    From 
      MakeDbLeagueBySize
    )
  Select 
    R.*, CASE WHEN RankingInLeague  = @seqCheckNow Or page_verify_option_desc <> 'CHECKSUM' THEN 1 ELSE 0 END as doFullCheckDb
  Into #DbToCheck
  From 
    AddRankingInEachLeague R
    Join
    Sys.Databases D On D.Name = R.DbName

  While(1 = 1) -- simulate simple do -- loop 
  Begin
    -- process on database at the time in name order
    Select top 1 
      @DbName = DbName
    , @cmptlevel = cmptlevel
    , @doFullCheckDb = doFullCheckDb
    From #DbToCheck
    Where DbName > @DbName -- next Dbname greater than @dbname
    Order By DbName -- dbName order 
    
    -- exit loop if no more name greater than the last one used
    If @@rowcount = 0 Break 

    Set @sql = 'DBCC checkDb("<DbName>") '+ Case When @doFullCheckDb = 0  Then ' WITH PHYSICAL_ONLY ' Else '' End

    Set @sql = replace(@sql,'<DbName>', @dbName )
    set @sql = replace(@sql,'"','''') -- useful to avoid duplicating of single quote in boilerplate 

    Set @ErrorN = 0
    Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.IntegrityTesting'
    , @sql = @sql
    , @JobNo = @JobNo
    , @ErrorN = @ErrorN Output
    
    If @errorN <> 0 
    Begin
      -- get current action, which is the latest (highest seq) for this spid and this job
      Declare @action XML
      Declare @seq Int
      Select Top 1 @seq = Seq 
      From Maint.JobHistoryDetails 
      Where jobNo = @jobNo 
      order by JobNo, seq desc

      If Not exists -- check if this action has no error 5128, put it offline
         (
         Select * 
         From 
           Maint.JobHistoryDetails 
         Where JobNo = @JobNo 
           And seq = @Seq
               -- The XML expression below try to locate Error 5128
               -- This error is due to lack of space so we don't put the database offline for this
               -- see the expression and the example below
           And action.exist('/Exec/err//text()[contains(.,"Error 5128")]')=1 
           /*
           <Exec>
             <ctx>yMaint.IntegrityTesting</ctx>
             <cmd>DBCC checkDb(''wslogdb70'')</cmd>
             <err>Error 5128, Severity 17, level 2 : Write to sparse file ''T:\Mssql\Data\wslogdb70.mdf:MSSQL_DBCC21'' failed due to lack of disk space.</err>
           </Exec>
           */
         )
       Exec yMaint.PutDbOffline @DbName, @JobNo
    End  

  End -- While boucle banque par banque

End -- yMaint.IntegrityTesting
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.UpdateStats'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
CREATE proc yMaint.UpdateStats
  @JobNo Int
, @SpreadUpdStatRun Int
as
Begin
  declare @seqStatNow  Int
  declare @cmptlevel Int
  declare @dbName sysname
  declare @sql nvarchar(max)
  declare @lockResult int
  Declare @seq Int                 -- row sequence for row by row processing
  Declare @scn sysname             -- schema name
  Declare @tb sysname              -- table name
  declare @sampling Int           -- page count to get an idea if the size of the table
  Declare @idx sysname             -- index name
  Declare @object_id int           -- a proof that an object exists

  Begin Try

  Create table #TableNames
  (
    scn sysname
  , tb sysname
  , sampling nvarchar(3)
  , seq int
  , primary key clustered (seq)
  )

  Update Maint.JobSeqUpdStat 
    Set @seqStatNow = (seq + 1) % @SpreadUpdStatRun, seq = @seqStatNow  

  Set @DbName = ''
  While(1 = 1) -- simple do loop
  Begin
    Select top 1 -- first next in alpha sequence after the last one.
      @DbName = DbName
    , @cmptLevel = CmptLevel  
    From #Db
    Where DbName > @DbName 
    Order By DbName 
    
    -- exit if nothing after the last one processed
    If @@rowcount = 0 Break -- 

    -- If database is not updatable, skip update stats for this database
    If DATABASEPROPERTYEX(@DbName, 'Updateability') = N'READ_ONLY'  
      Continue

    -- If database is in emrgency, skip update stats for this database
    If DatabasepropertyEx(@DbName, 'Status') = 'OFFLINE'
      Continue
      
    -- makes query boilerplate with replacable parameter identified by
    -- labels between "<" et ">"
    -- this query select table for which to perform update statistics
    truncate table #TableNames
    set @sql =
    '
     Use [<DbName>]
     set nocount on
     ;With
       TableSizeStats as
     (
     select 
       object_schema_name(Ps.object_id) as scn --collate <srvCol>
     , object_name(Ps.object_id) as tb --collate <srvCol>
     , Sum(Ps.Page_count) as Pg
    From
      sys.dm_db_index_physical_stats (db_id("<DbName>"), NULL, NULL, NULL, "LIMITED") Ps
    Where (   OBJECTPROPERTYEX ( Ps.object_id , "IsTable" ) = 1
           Or OBJECTPROPERTYEX ( Ps.object_id , "IsView" ) = 1)
    Group by 
      Ps.object_id  
    )
    Insert into #tableNames (scn, tb, seq, sampling)
    Select 
      scn
    , tb
    , row_number() over (order by scn, tb) as seq
    , Case 
        When Pg > 5000001 Then "0"
        When Pg between 1000001 and 5000000 Then "1"
        When Pg between 500001 and 1000000 Then "5"
        When pg between 200001 and 500000 Then "10"
        When Pg between 50001 and 200000 Then "20"
        When Pg between 5001 and 50000 Then "30"
        else "100"
      End  
    From 
      TableSizeStats
    where scn is not null and tb is not null and (abs(checksum(tb)) % <SpreadUpdStatRun>) = <seqStatNow>
    '  
    set @sql = replace(@sql,'<srvCol>',convert(nvarchar(100), Serverproperty('collation'))) 
    Set @sql = replace(@sql,'<seqStatNow>', convert(nvarchar(20), @seqStatNow))
    Set @sql = replace(@sql,'<SpreadUpdStatRun>', convert(nvarchar(20), @SpreadUpdStatRun))
    set @sql = replace(@sql,'"','''') -- to avoid doubling of quotes in boilerplate
    set @sql = replace(@sql,'<DbName>',@DbName) 

    Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.UpdateStats'
    , @Info = 'Table selection for update statistics'  
    , @sql = @sql
    , @JobNo = @JobNo
    , @forDiagOnly  = 1

    set @seq = 0
    While (1 = 1)
    begin
      Select top 1 @scn = scn, @tb = tb, @sampling = sampling, @seq = seq
      from #TableNames where seq > @seq order by seq
      if @@rowcount = 0 break


      Set @sql = 'Select @object_id = object_id("<DbName>.<scn>.<tb>") '
      set @sql = replace (@sql, '<DbName>', @DbName)
      set @sql = replace (@sql, '<scn>', @scn)
      set @sql = replace (@sql, '<tb>', @tb)
      set @sql = replace (@sql, '"', '''')
      Exec sp_executeSql @Sql, N'@object_id  int output', @object_id output

      If @object_id is not null
      Begin
        Set @sql = 'update statistics [<DbName>].[<scn>].[<tb>] WITH sample <sampling> PERCENT'
        set @sql = replace (@sql, '<DbName>', @DbName)
        set @sql = replace (@sql, '<scn>', @scn)
        set @sql = replace (@sql, '<tb>', @tb)
        If @sampling = 0 
          set @sql = replace (@sql, 'WITH Sample <sampling> PERCENT', '')
        Else 
        BEGIN
          If @sampling < 100 
            set @sql = replace (@sql, '<sampling>', Str(@sampling))
          Else 
            set @sql = replace (@sql, 'Sample <sampling> PERCENT', 'FULLSCAN')
        END
      
        set @sql = replace (@sql, '"', '''')
        Exec yExecNLog.LogAndOrExec 
          @context = 'yMaint.UpdateStats'
        , @Info = 'update statistics selected'  
        , @sql = @sql
        , @JobNo = @JobNo
      End
    end -- While

  End -- While boucle banque par banque

  End try
  Begin catch
    Exec yExecNLog.LogAndOrExec @jobNo = @jobNo, @context = 'yMaint.UpdateStats Error', @err = '?'
  End Catch
End -- yMaint.UpdateStats
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.ReorganizeOnlyWhatNeedToBe'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
CREATE proc yMaint.ReorganizeOnlyWhatNeedToBe
  @JobNo int
as
Begin
  declare @cmptlevel Int
  declare @dbName sysname
  declare @sql nvarchar(max)
  declare @lockResult int
  Declare @seq Int                 -- row sequence in work table
  Declare @scn sysname             -- schema name
  Declare @tb sysname              -- table name
  Declare @td sysname              -- object type
  Declare @idx sysname             -- index name
  Declare @colName sysname             -- index column name
  Declare @pgLock int              -- index page_locking flag
  Declare @partitionNum Int
  Declare @frag float
  Declare @index_type_desc NVARCHAR(60)
  Declare @Page_count BigInt
  Declare @alloc_unit_type_desc NVARCHAR(60) 
  Declare @TotPartNb Int
  Declare @Info nvarchar(max)
  Declare @ReorgType nvarchar(10)

  Begin Try 

  Declare @recMode sysname

  Create table #IndexNames
  (
    scn sysname null
  , tb sysname null
  , td sysname null
  , idx sysname null
  , pgLock int  null
  , partitionnum Int null
  , frag float null
  , index_type_desc NVARCHAR(60) null
  , Page_count BigInt null
  , alloc_unit_type_desc NVARCHAR(60) null
  , TotPartNb Int null
  , colname Sysname null
  , ReorgType as 
      Case 
        When (frag between 5.0 and 30.0 And pgLock = 1 and page_count > 8) 
        Then 'Reorg'
        When (frag > 30.0 and page_count > 8) Or (frag > 5.0 and pgLock = 0 and page_count > 8) 
        Then 'Rebuild'
        Else ''
      End 
  , seq int
  , primary key clustered (seq)
  )

  Set @DbName = ''
  While(1 = 1) -- Emulate simple loop, exit internally by a break statement on a given condition
  Begin
    -- read only one database at the time
    -- Top 1 clause with order is used to get the next database
    -- in alphebetic order and which is next to the last database name processed or ""
    -- makes simpler shorter and ffaster code than using cursors

    Select top 1 
      @DbName = DbName
    , @cmptLevel = CmptLevel  
    From #Db
    Where DbName > @DbName 
    Order By DbName 
    
    -- If there is no next database to the last one read
    If @@rowcount = 0 Break -- exit

    -- If database is not updatable, GO to the next in the list
    If DATABASEPROPERTYEX(@DbName, 'Updateability') = N'READ_ONLY'  
      Continue

    -- If database is not updatable, GO to the next in the list
    If DatabasepropertyEx(@DbName, 'Status') IN (N'EMERGENCY', N'OFFLINE')
      Continue

    truncate table #IndexNames
    set @sql =
    '
    Use [<DbName>]
    set nocount on
    insert into #IndexNames 
      ( scn, tb, td, IDX, pglock, partitionnum, frag, index_type_desc
      , Page_count, alloc_unit_type_desc, TotPartNb, ColName
      , seq)
    select 
      S.name --collate <srvCol> 
    , OBJ.name --collate <srvCol>
    , OBJ.type_desc --collate <srvCol> 
    , IDX.name 
    , IDX.allow_page_locks 
    , PS.partition_number AS partitionnum
    , PS.avg_fragmentation_in_percent AS frag
    , IDX.type_desc 
    , PS.Page_count
    , PS.alloc_unit_type_desc 
    , Max (partition_number) OVER(PARTITION BY IDX.object_id, IDX.index_id) as TotPartNb
    , (
      select top 1 SC.name from sys.columns SC 
      Where SC.object_id = IDX.object_id And Columnproperty(OBJ.object_id, SC.name, "IsIndexable") = 1  -- Version 1.2  
      Order by SC.column_id
      ) as ColName
    , row_number() over (order by S.name, OBJ.name, IDX.name, PS.partition_number) as seq
    From
      sys.dm_db_index_physical_stats (db_id("<DbName>"), NULL, NULL, NULL, "LIMITED") PS
      join --cross join
      sys.indexes IDX
      on IDX.object_id = PS.object_id And IDX.index_id = PS.index_id
      join
      sys.objects OBJ
      on IDX.object_id = OBJ.object_id 
      join 
      sys.schemas S
      on S.schema_id = OBJ.schema_id
      
    Where PS.avg_fragmentation_in_percent > 5
      and OBJ.type_desc = "User_Table" 
    '  

    -- Version 1.2  
    If not exists (select * from sys.databases where name = @DbName And compatibility_level >= 90)
    Begin
      Set @sql = 
          replace 
          (@sql, 
          'sys.dm_db_index_physical_stats (db_id("<DbName>"), NULL, NULL, NULL, "LIMITED")',
          '(select 0 as partition_number, 100 as avg_fragmentation_in_percent, 1000 as Page_count, "" as alloc_unit_type_desc)'
          )
      Set @sql = replace (@sql, 'join --cross join', 'Cross join')
      Set @sql = replace (@sql, 'on Idx.object_id = Ps.object_id And Idx.index_id = Ps.index_id', '')    
    End
    -- Version 1.2  

    set @sql = replace(@sql,'<srvCol>',convert(nvarchar(100), Serverproperty('collation'))) 
    set @sql = replace(@sql,'"','''') -- trick to use " instead of doubling quotes in query string

    set @sql = replace(@sql,'<DbName>',@DbName) 
   
    Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.ReorganizeOnlyWhatNeedToBe'
    , @Info = 'Get index list of indexes to reorganize'
    , @sql = @sql
    , @JobNo = @JobNo
    , @forDiagOnly  = 1
    
    -- select 'trace', * from #IndexNames 
    
    -- makes query boilerplate with replacable parameter identified by
    -- labels between "<" et ">"
  
    -- build only one message for tables that need not defrag of any indexes
    Select @info =
    (      
    Select 
      Convert (nvarchar(max), '') + scn + '.' + tb + NCHAR(10) as [text()]
    from #IndexNames 
    --Where index_type_desc <> 'HEAP'
    Group By scn, tb
    Having Min(ReorgType) = ''
    for XML PATH('')
    )

    set @Info = 'Index and heap Reorg' + nchar(10) + 
                'Defragmentation not needed to be done in ' + @DbName+ ' for tables:' + NCHAR(10) + @info
    Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.ReorganizeOnlyWhatNeedToBe'
    , @Info = @info
    , @JobNo = @JobNo
    , @forDiagOnly  = 0
      
    -- process defrag  
    set @seq = 0
    While (1 = 1)
    begin
      Select top 1 
        @scn = scn, @tb = tb, @idx = idx, @pgLock = pgLock, 
        @partitionNum = partitionnum, @index_type_desc = index_type_desc, 
        @alloc_unit_type_desc = alloc_unit_type_desc, 
        @TotPartNb = TotPartNb, @Colname = Colname, @ReorgType = ReorgType,
        @seq = seq
      from #IndexNames I
      where 
            seq > @seq
--      And index_type_desc <> 'HEAP' 
      order by seq
      if @@rowcount = 0 break

      If @index_type_desc <> 'HEAP'
      Begin 
        Set @sql =
        Case 
          When @ReorgType = 'Reorg'
          Then '
                ALTER INDEX [<idx>] ON [<DbName>].[<scn>].[<tb>] 
                Reorganize PARTITION = <partition_number> 
                With (LOB_COMPACTION = On)
                ' 
          When @ReorgType = 'Rebuild'
          Then '
                ALTER INDEX [<idx>] ON [<DbName>].[<scn>].[<tb>] Rebuild;
                '
          Else ''
        End 
      End  
      Else -- don't try to handle heap
      Begin 
    --   don't try to reorganize Heap 
    --  If @page_count > 8  And @colName is not NULL -- Version 1.2  
    --    Set @sql =
    --    '
    --    Use [<DbName>]
    --    Create clustered index [IdxDefrag] ON [<scn>].[<tb>]  ([<colName>]) with (fillfactor = 95);
    --    Exec("Drop index [<scn>].[<tb>].[IdxDefrag]")  
    --    ' 
    --  Else 
        Set @sql = ''
      End
          
      set @sql = replace (@sql, '<scn>', @scn collate database_default)
      set @sql = replace (@sql, '<tb>', @tb collate database_default)
      set @sql = replace (@sql, '<idx>', isnull(@idx, '') collate database_default)
      set @sql = replace (@sql, '<colName>', @colName collate database_default) -- if no clustered index
      set @sql = replace (@sql, '<DbName>', @DbName collate database_default)
      set @sql = replace (@sql, '"', '''')
      
      If @TotPartNb > 1 
        Set @sql = replace(@sql, '<partition_number>', Convert(nvarchar(20), @partitionNum))
      Else   
        Set @sql = replace(@sql, 'PARTITION = <partition_number>', '')

      If @sql <> ''
        Exec yExecNLog.LogAndOrExec 
          @context = 'yMaint.ReorganizeOnlyWhatNeedToBe'
        , @Info = 'Index and heap Reorg'  
        , @sql = @sql
        , @JobNo = @JobNo
    End -- While loop index by index

  End -- While loop database by database
  
  End try
  Begin catch
    Exec yExecNLog.LogAndOrExec @jobNo = @jobNo, @context = 'yMaint.ReorganizeOnlyWhatNeedToBe Error', @err='?'
  End Catch

End -- yMaint.ReorganizeOnlyWhatNeedToBe
GO

-- ------------------------------------------------------------------------------
-- Function that get the installation language of the instance
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yInstall.InstallationLanguage'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO

CREATE Procedure yInstall.InstallationLanguage
  @language nvarchar(512) output
as
Begin
 
  create table #SVer(ID int,  Name  sysname, Internal_Value int, Value nvarchar(512))
  insert #SVer exec master.dbo.xp_msver Language
  
  Select @language = Value from #SVer where Name = N'Language'
  
End -- yInstall.InstallationLanguage
GO

-- ------------------------------------------------------------------------------
-- Function that builds backup file name
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.MakeBackupFileName'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO

CREATE function yMaint.MakeBackupFileName
(
  @DbName sysname
, @bkpTyp Char(1)
, @FullBackupPath nvarchar(512)
, @Language nvarchar(512)
, @Ext nvarchar(7) = NULL
, @TimeStampNamingForBackups Int = 1
)
returns nvarchar(max)
as
Begin
  -- ===================================================================================== 
  -- Find weekday name which is part of generated backup name
  -- ===================================================================================== 

  -- Find weekday from date.  

  Declare @DayOfWeek   nvarchar(8)
  Declare @DayOfWeekNo    Int
  Declare @DayOfWeekNoStr Char(1)
  Declare @filename  nvarchar(512)

  declare @BackupTimeStamp nvarchar(60)
  
  If @DbName <> 'msdb'
  Begin 
    Set @BackupTimeStamp = Convert(nvarchar(30), getdate(), 120)
    Set @BackupTimeStamp = STUFF (@BackupTimeStamp, 11, 1, '_')
    Set @BackupTimeStamp = STUFF (@BackupTimeStamp, 14, 1, 'h')
    Set @BackupTimeStamp = STUFF (@BackupTimeStamp, 17, 1, 'm')
  End
  Else
  Begin
    -- for MSDB we don't keep time part in the timestamp just date part because
    -- MSDB is taken in backup many times a day
    Set @BackupTimeStamp = Convert(nvarchar(10), getdate(), 121)  
  end
      
  -- use independant Set datefirst setting using @@datefirst 
  -- to get a predictible @dayOfWeekNo.  Set datefirst value is dependent of language
  Set @DayOfWeekNo = ((@@datefirst + DatePart(dw, getdate())) % 7) + 1

  -- @DayOfWeekNo = Sat = 0 Sun = 1 Mon = 2....
  -- translate Sat = 0 by Sat = 6, Sun = 1 par Sun = 7 an so on
  Set @DayOfWeekNoStr = Substring('6712345', @DayOfWeekNo, 1) 
  
  Set @DayOfWeek = 
  Case 
    When @Language like 'Français%' Then -- default french language server
      case @DayOfWeekNoStr
        when '1' then 'Lun'
        when '2' then 'Mar'
        when '3' then 'Mer'
        when '4' then 'Jeu'
        when '5' then 'Ven'
        when '6' then 'Sam'
        when '7' then 'Dim'
      end
    Else -- else default to us-english
      case @DayOfWeekNoStr
        when '1' then 'Mon'
        when '2' then 'Tue'
        when '3' then 'Wed'
        when '4' then 'Thu'
        when '5' then 'Fri'
        when '6' then 'Sat'
        when '7' then 'Sun'
      end
  End            
  -- Make file name boiler plate with replaceable parameters identified by label  between "<" et ">"
  Set @filename = '<destin><DbName>_[<DteHr>_<jour>]_<typ>.<ext>'

  -- replace parameters ....
  Set @filename = replace(@filename,'<destin>', yUtl.NormalizePath(@FullBackupPath))

  If @bkpTyp = 'F'
     Set @filename = replace(@filename,'<typ>', 'database')
  Else If @bkpTyp = 'D'
     Set @filename = REPLACE(@filename,'<typ>', 'differential')
  Else   
     Set @filename = replace(@filename,'<typ>', 'logs')

 
  -- generate logs by day by default
  If @TimeStampNamingForBackups IS NULL Or  @TimeStampNamingForBackups = 1 
  Begin 
    Set @filename = replace(@filename,'<jour>', @DayOfWeek) 
    Set @filename = replace(@filename,'<DteHr>', @BackupTimeStamp) 
  End
  Else
    Set @filename = replace(@filename,'[<DteHr>_<jour>]_', '');

  -- set extension and db name as part of the file name
  Set @filename = replace(@filename,'<ext>',  case when @bkpTyp = 'F' Then ISNULL(@Ext, 'Bak') else ISNULL(@Ext, 'Trn') end) 
  Set @filename = replace(@filename,'<DbName>', @DbName) -- nom de la Bd

  Return (@filename)
  
End -- yMaint.MakeBackupFileName
GO
-- ------------------------------------------------------------------------------
-- Function that builds backup command
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.MakeBackupCmd'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create function yMaint.MakeBackupCmd
(
  @DbName sysname
, @bkpTyp Char(1)
, @fileName nvarchar(512)
, @overwrite Int
, @name nvarchar(512)
)
returns nvarchar(max)
as
Begin

  Declare @sql       nvarchar(max)

  -- Make query boilerplate with replaçable parameters delimited by "<" and ">"
  -- double quotes are replaced by 2 single quotes. This trick avoid the unreadability
  -- of double single quotes
  Set @sql = 
  '
   backup <typ> [<DbName>] 
   to disk = "<fileName>" 
   with <repl><diff>, checksum, name = "<name>"
   '

  set @sql = replace(@sql,'"','''') -- trick that avoid doubling single quote in the boilerplate

  If @bkpTyp = 'F' Or @bkpTyp = 'D'
     Set @sql = replace(@sql,'<typ>', 'database')
  Else   
     Set @sql = replace(@sql,'<typ>', 'log')

  Set @sql = replace(@sql,'<DbName>', @DbName) -- nom de la Bd
  
  Set @sql = replace(@sql,'<repl>', case when @overwrite = 1 Then 'Init, Format' else 'noInit' end) 

  Set @sql = replace(@sql,'<diff>', case when @bkpTyp = 'D' Then ', DIFFERENTIAL' else '' end) 

  Set @sql = Replace(@sql, '<Filename>', @filename)

  Set @name = 
      case 
        when @name like 'SaveDbOnNewFileSet%' Then 'SaveDbOnNewFileSet'
        Else 'YourSQLDba'
      End + ':'+replace(left(convert(varchar(8), getdate(), 108),5), ':', 'h')+': '+@filename
 
  -- backup name (not file backup name, but name parameter of backup command)
  -- is limited to 128, must be truncated accordingly before time stamps
  -- patindex below finds position just before timestamps in the name
  Declare @pos int
  Declare @fin nvarchar(100)

  If len(@name) > 128
  Begin
    If @bkpTyp = 'F' 
      Set @pos = Patindex ('%[_]_________________________[_]database.Bak', @name)
    Else 
      Set @pos = Patindex ('%[_]_________________________[_]logs.trn', @name);

    Set @fin = Substring(@name, @pos, 255)
    Set @name = left(@name, 128 - len(@fin) - 3) + '...' + @fin
  End
  
  Set @sql = replace(@sql,'<name>', @name)

  Return (@sql)
  
End -- yMaint.MakeBackupCmd
GO

-- ------------------------------------------------------------------------------
-- Function that builds backup command (auto activated stored proc on queue
-- YourSQLDbaTargetQueueMirrorRestore )
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMirroring.Broker_AutoActivated_LaunchRestoreToMirrorCmd'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create procedure yMirroring.Broker_AutoActivated_LaunchRestoreToMirrorCmd
as
begin
  Declare @RecvReqDlgHandle uniqueidentifier;
  Declare @RecvReqMsg xml
  Declare @RecvReqMsgName sysname;
  Declare @JobNo int
  Declare @seq int
  Declare @sql nvarchar(max)
  Declare @ReplyMsg xml;
  Declare @errorN Int;
  Declare @err nvarchar(max);

  WHILE (1=1)
  BEGIN
    
    -- The RECEIVE is not in transaction to prevent the call «Exec yExecNLog.LogAndOrExec»
    -- fromg frezzing.  Because there is no transaction only 1 procedure should be activated 
    -- for this Queue.
    WAITFOR
    ( RECEIVE TOP(1)
        @RecvReqDlgHandle = conversation_handle,
        @RecvReqMsg = convert(xml, message_body),
        @RecvReqMsgName = message_type_name
      FROM YourSqlDbaTargetQueueMirrorRestore
    ), TIMEOUT 1000;
    
    IF (@@ROWCOUNT = 0)
    BEGIN
      BREAK;
    END    
    
    IF @RecvReqMsgName = N'//YourSQLDba/MirrorRestore/End'
    BEGIN
      END CONVERSATION @RecvReqDlgHandle    
    END

    IF @RecvReqMsgName = N'//YourSQLDba/MirrorRestore/Request'
    BEGIN
      Set @JobNo = @RecvReqMsg.value('JobNo[1]', 'int')
      Set @seq = @RecvReqMsg.value('Seq[1]', 'int')
      Set @sql = @RecvReqMsg.value('sql[1]', 'nvarchar(max)')
               
      Exec yExecNLog.LogAndOrExec 
        @context = 'yMirroring.Broker_AutoActivated_LaunchRestoreToMirrorCmd'
      , @Info = 'Remote restore diagnostics here'
      , @sql = @sql
      , @JobNo = @JobNo
      , @errorN = @errorN output
      , @err = @err output

      SELECT @ReplyMsg = 
             (SELECT 
                @JobNo as JobNo
              , @seq as Seq
              , Case When @errorN > 0 Then 'Failure: ' Else 'Success: ' End+
              @sql+
              case when @errorN > 0 Then @err Else '' End as Info 
              FOR XML PATH('')
              );


      SEND ON CONVERSATION @RecvReqDlgHandle
          MESSAGE TYPE 
          [//YourSQLDba/MirrorRestore/Reply]
          (@ReplyMsg);
      
    END --IF @RecvReqMsgName = N'//YourSQLDba/MirrorRestore/Request'
    
    IF @RecvReqMsgName not in (N'//YourSQLDba/MirrorRestore/Request', N'//YourSQLDba/MirrorRestore/End')
    Begin
      declare @Info nvarchar(max)
      Set @Info = 'Message name unexpected: ' + @RecvReqMsgName
      Exec yExecNLog.LogAndOrExec 
        @context = 'yMirroring.Broker_AutoActivated_LaunchRestoreToMirrorCmd'
      , @Info = @Info
      , @JobNo = @JobNo
    End
    
  END --WHILE (1=1)

End
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMirroring.QueueRestoreToMirrorCmd'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create procedure yMirroring.QueueRestoreToMirrorCmd
  @context nvarchar(4000) = ''
, @JobNo Int
, @DbName sysname
, @bkpTyp Char(1)
, @fileName nvarchar(512)
, @MirrorServer sysname
, @ReplaceSrcBkpPathToMatchingMirrorPath nvarchar(max) = ''
, @ReplacePathsInDbFilenames nvarchar(max) = ''
, @BrokerDlgHandle uniqueidentifier OUT
as
Begin

  Declare @sql       nvarchar(max)
  Declare @Info nvarchar(max)
  Declare @err nvarchar(max)
  Declare @RequestMsg xml  
  Declare @seq int

  -- If the mirror server is disabled or this is a system database then return
  -- easier to trace in profiler if written this way
  If isnull(@MirrorServer, '') = '' 
    Return(0)
  If @DbName in ('master', 'model', 'msdb', 'tempdb', 'YourSQLDba')
    Return( 0 )
    
  -- Test that the Mirror server was defined  
  If Not Exists (Select * From Mirroring.TargetServer Where MirrorServerName = @MirrorServer)
  Begin
    Set @err = 'Mirror server «' + @MirrorServer + '» not defined.  Use stored procedure «Mirroring.AddServer»'
    Exec yExecNLog.LogAndOrExec 
      @context = 'yMirroring.QueueRestoreToMirrorCmd'
    , @Info = 'Error at launch restore to mirror server'
    , @YourSqlDbaNo = '008'
    , @Err = @Err
    , @JobNo = @JobNo
    
    Return( 0 )
  End

  -- Make query boilerplate with replaçable parameters delimited by "<" and ">"
  -- double quotes are replaced by 2 single quotes. This trick avoid the unreadability
  -- of double single quotes
  Set @sql = '
  Exec [<MirrorServer>].YourSqlDba.yMirroring.DoRestore 
    @BackupType="<BackupType>"
  , @Filename="<Filename>"
  , @DbName="<DbName>"
  , @ReplaceSrcBkpPathToMatchingMirrorPath="<ReplaceSrcBkpPathToMatchingMirrorPath>"
  , @ReplacePathsInDbFilenames = "<ReplacePathsInDbFilenames>"
  '

  Set @sql = REPLACE(@sql, '<BackupType>', @bkpTyp)
  Set @sql = REPLACE(@sql, '<Filename>', @fileName)
  Set @sql = REPLACE(@sql, '<DbName>', @DbName)
  Set @sql = REPLACE(@sql, '<MirrorServer>', @MirrorServer)  
  Set @sql = REPLACE(@sql, '<ReplaceSrcBkpPathToMatchingMirrorPath>', yUtl.NormalizeLineEnds (isNull(@ReplaceSrcBkpPathToMatchingMirrorPath,'')))  
  Set @sql = REPLACE(@sql, '<ReplacePathsInDbFilenames>', yUtl.NormalizeLineEnds (isnull(@ReplacePathsInDbFilenames,'')))  
  Set @sql = REPLACE(@sql, '"', '''')

  Set @Info = 'Restore to mirror server sent to Broker (waiting for activation):' + @sql
  Exec yExecNLog.LogAndOrExec 
    @yourSqlDbaNo='020'
  , @context='yMirroring.QueueRestoreToMirrorCmd'
  , @Info = @info
  , @jobNo = @JobNo

  Set @seq = scope_identity()
  
  Select @RequestMsg =
    (
    Select @JobNo as JobNo, @seq as Seq, @sql as sql
    For Xml Path('')
    )
    
  BEGIN TRAN    
  
  begin try
  
    If @BrokerDlgHandle Is Null
    Begin
      BEGIN DIALOG @BrokerDlgHandle
      FROM SERVICE [//YourSQLDba/MirrorRestore/InitiatorService]
      TO SERVICE '//YourSQLDba/MirrorRestore/TargetService'
      ON CONTRACT [//YourSQLDba/MirrorRestore/Contract]
      WITH ENCRYPTION = OFF;
    End;
    
    SEND ON CONVERSATION @BrokerDlgHandle
        MESSAGE TYPE [//YourSQLDba/MirrorRestore/Request]
        (@RequestMsg);
        
    COMMIT TRAN          
  End try 
  Begin catch
    Exec yExecNLog.LogAndOrExec 
      @yourSqlDbaNo='020'
    , @context='yMirroring.QueueRestoreToMirrorCmd'
    , @Info = 'Restore to mirror server sent to Broker (waiting for activation)'
    , @err = '?'
    , @sql = @sql
    , @jobNo = @JobNo
  End catch
  
End -- yMirroring.QueueRestoreToMirrorCmd
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.DropOrphanLogins'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create procedure Maint.DropOrphanLogins
as
begin
  create table #logins (name sysname primary key clustered)
  declare @sql nvarchar(max)

  Select @sql =
  (
  select convert(nvarchar(max), '') +
  'select suser_sname(sid) from ['+name+'].sys.database_principals where suser_sname(sid) is not null union '+nchar(10) as [text()]
  From sys.databases
  for XML path('')
  )+
  'Select '''' as name'
  insert into #logins Exec(@sql)

  Select @sql =
  (
  Select convert(nvarchar(max), '') + 'drop login ['+sp.name+']'+nchar(10) as [text()]
  from 
    sys.server_principals SP
    left join
    #logins L
    ON  SP.name = L.Name
  Where type_desc = 'SQL_LOGIN' and L.name is null
  for XML path('')
  )
  print @sql
  Exec(@sql)
End
go
-- ------------------------------------------------------------------------------
-- Procedure to delete old backup files selected by all the following conditions:
--
-- 1. The files must be in the files path @path.
--    (subdirectories are not selected).
--
-- 2. The files name must contain the date and time of its creation.
--    The format is like 
--    '%[_][[][0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][_][0-9][0-9]h[0-9][0-9]m[0-9][0-9][_]___][_]%'
--    Example: AdventureWorks_[2009-04-27_00h06m53_Mon]_database.Bak
--  and
--    The files name must end with the optional @extension.
--
-- 3.   ( @BkpRetDays is not NULL
--      and
--        The beginning of the file name is in the selected database list in the 
--        temporary table @tDb
--      and 
--        AgeInMinutes > (@BkpRetDays * 1440)           -- AgeInMinutes is the age of the file in minutes
--      )
--    Or
--      ( @BkpRetDaysForUnSelectedDb is not NULL  
--      and
--        The file was not selected by @tDb
--      and
--        AgeInMinutes > (@BkpRetDaysForUnSelectedDb * 1440)  -- AgeInMinutes is the age of the file in minutes
--      )
--
-- In all cases, the msdb database file backup is always deleted by  
-- the Maint.DeleteOldBackups procedure when  @extension = .bak
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.DeleteOldBackups'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
CREATE Procedure Maint.DeleteOldBackups
  @oper nvarchar(200) = 'YourSQLDba_Operator'
, @command nvarchar(200) = 'DeleteOldBackups' -- main command
, @MaintJobName nvarchar(200) = 'YourSqlDba_DeleteOldBackups'
, @path nVARCHAR(max)  -- Path to the files
, @BkpRetDays Int = NULL     -- Number of days to keep the backup files
                             -- selected by there database name.
                             -- by default no cleanup.
, @BkpRetDaysForUnSelectedDb int = NULL   -- Optional number of days to keep the backup
                                          -- files not selected by there database name.
                                          -- by default no cleanup.  
, @RefDate Datetime = NULL  -- Optional reference date and time for the clean up  
                            -- Format:  '20090925 18:00'
                            --           yyyymmdd hh:mm
, @extension sysname = ''   -- Optional file extention 
                            -- any file extension of any length is accepted
                            -- Examples: .bak for full backups  
                            -- or .trn for log backups
                            -- or '' for all files in the @path
, @IncDb nVARCHAR(max) = '' 
, @ExcDb nVARCHAR(max) = '' 
, @JobNo Int = NULL              -- job number of the maintenance task
, @SendOnErrorOnly int = 1  -- 1 = send an email only when there is an error
as
Begin
  Set NoCount On
  
  Declare @Info nvarchar(max)
  Declare @FullFilePath nvarchar(max) 
  declare @err nvarchar(max)
  
  If @RefDate is NULL
    Set @RefDate = convert(datetime, getdate(), 120)
  
  If Right(@path, 1) <> '\'
    Set @path = @path + '\'


  Declare @StartOfCleanup datetime   

  set @StartOfCleanup = getdate()

  If @JobNo is NULL   -- Maint.DeleteOldBackups was called from a query window
  Begin
    -- Create a new job entry in the job history table
    
    exec yExecNLog.AddJobEntry 
      @jobName = 'DeleteOldBackups'
    , @JobNo = @JobNo output -- if null in output a new is made, otherwise append job specified
    
    Update Maint.JobHistory 
    Set 
      JobEnd = GETDATE()
    , IncDb = @incDb
    , ExcDb = @ExcDb
    , FullBkpRetDays = @BkpRetDays                         
    , LogBkpRetDays = 0
    , FullBackupPath = @path                      
    , ConsecutiveDaysOfFailedBackupsToPutDbOffline = 9999
    , BkpLogsOnSameFile = 0
    Where JobNo = @JobNo
  End  

  Exec yExecNLog.LogAndOrExec 
      @context = 'Maint.DeleteOldBackups'
    , @Info = 'Start of backup cleanup'
    , @JobNo = @JobNo

  -- Create a table of the databases selected
  declare @tDb table 
  (
    DbName sysname collate database_default primary key clustered
  , DbOwner sysname
  , FullrecoveryMode int    -- If = 1 log backup allowed
  , cmptLevel tinyInt
  )

  insert into @tDb
  SELECT * 
  FROM 
    YourSQLDba.yUtl.YourSQLDba_ApplyFilterDb (@IncDb, @ExcDb)
  Where DatabasepropertyEx(DbName, 'Status') = 'Online' -- Avoid db that can't be processed
  
  --select * from @tDb

  -- remove snapshot database from the list
  Delete Db
  From @tDb Db
  Where 
    Exists
    (
    Select * 
    From sys.databases d 
    Where d.name COLLATE Database_default = db.DbName 
      and source_database_Id is not null
    )

  --select * from @tDb

  -- create table of directory info lines
  declare @FilesFromFolder table ( line nvarchar(1000) collate database_default)

  If LEFT(@extension,1)<> '.' Set @extension = '.'+@extension 

  Insert into @FilesFromFolder
  Select * from yUtl.Clr_GetFolderList (@path, '*'+@extension)
  
  If Exists(Select * from @FilesFromFolder Where line = '<ERROR>')
  Begin
    Set @err = 
    (
    Select CONVERT(nvarchar(max),'')+Line+NCHAR(10) as [text()]
    From @FilesFromFolder
    Where line <> '<ERROR>'
    for XML PATH('')
    )
    Exec yExecNLog.LogAndOrExec  
      @context = 'Maint.DeleteOldBackups'
    , @err = @err
    , @JobNo = @JobNo
    Return
  End  

  --SELECT *
  --From @FilesFromFolder
  
  declare @dbFiles table 
  (
    Seq int primary key clustered
  , DbName sysname null
  , FileName nvarchar(max) null 
  , Creation_Date nvarchar(23) null
  , RefDate nvarchar(23) null
  , AgeInMinutes Int null
  )
  ;With FilesReturnedBy_Clr_GetFolderList
   as
   (
   SELECT 
     ROW_NUMBER() OVER (ORDER BY d.line) As Seq
   , ltrim(rtrim(d.line)) as FileName
   , patindex ('%[_][[][0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][_][0-9][0-9]h[0-9][0-9]m[0-9][0-9][_]___][_]%'
              , d.line) as posPatternDate
   , patindex ('MSDB_[[]%', d.line) as PosMsdb
   FROM @FilesFromFolder as d
   )
   , T1 as 
   (
   select 
     seq
   , FileName
   , Case 
       When PosMsDb > 0 Then Substring(FileName, posMsdb+6, 10) + ' 00:00'
       Else Substring(FileName, posPatternDate+2, 16) 
     End as DateCreate   
   From FilesReturnedBy_Clr_GetFolderList
   Where 
      PosMsDb > 0 
   Or PosPatternDate > 0
   )
   , T2 as (select seq, FileName, replace(DateCreate, 'h', ':') as DateCreate From T1)
   , T3 as (select seq, FileName, replace(DateCreate, '_', ' ') as DateCreate From T2)
   , T4 as 
   (
   select Distinct -- distinct helped to circumvent a funny run-time error
     seq
   , FileName
   , convert(datetime, DateCreate, 121) as Creation_Date 
   , @RefDate As RefDate 
   -- There is 1440 minutes per day
   , datediff(mi, convert(datetime, DateCreate, 121), @RefDate) As AgeInMinutes
   From T3
   )
 Insert into @dbFiles   
 Select F.Seq, db.DbName, F.FileName, F.Creation_Date, F.RefDate, F.AgeInMinutes 
 From 
   T4 as f
   Left Join
   @tDb as db
   On (db.DbName + '_[') = (Substring(f.FileName, 1, len(db.DbName) + 2 ))  
 Where 
       (   (@BkpRetDays is not NULL)  
       and (f.AgeInMinutes > (@BkpRetDays * 1440))  
       and (db.DbName Is Not Null)                    -- The file was selected by @tDb
       )                 
    Or
       (Substring(f.FileName, 1, 6) = 'MSDB_[')       -- Always delete old backups from MSDB
    Or 
       (   (@BkpRetDaysForUnSelectedDb is not NULL)   -- Delete files not seleted by @tDb
       and (db.DbName Is Null)                        -- The file was not selected by @tDb
       and (f.AgeInMinutes > (@BkpRetDaysForUnSelectedDb * 1440) ))

  --SELECT *
  --, (@BkpRetDays * 1440) as 'BkpRetDays in minutes'
  --, (@BkpRetDaysForUnSelectedDb * 1440) as 'BkpRetDaysForUnSelectedDb in minutes'
  --From @DbFiles
  --Order by FileName
  
  Declare @Cmd nvarchar(1000)
  declare @filename nvarchar(max)
  declare @dbName sysname
  declare @SeqFile int
  declare @context nvarchar(max)
  Set @SeqFile = 0

  Set @filename = ''
  While (1=1)
  Begin
    Select top 1 @filename = FileName, @SeqFile = seq, @dbName = dbName
    From @DbFiles 
    Where Seq > @SeqFile
    Order by seq

    If @@rowcount = 0 Break

    Set @FullFilePath = @path+@Filename
    
    Exec yUtl.Clr_DeleteFile @FullFilePath, @Err output
    If @err <> '' -- If file is not found no error is generated
    Begin
      Exec yExecNLog.LogAndOrExec 
        @context = 'Maint.DeleteOldBackups'
      , @err = @err
      , @JobNo = @JobNo
    end  
    Else
    Begin
      Set @FullFilePath = @FullFilePath + ' deleted'
      Exec yExecNLog.LogAndOrExec 
        @context = 'Maint.DeleteOldBackups'
      , @info = @FullFilePath  
      , @JobNo = @JobNo
    End
  End -- While

  Update Maint.JobHistory 
  Set JobEnd = Getdate()
  Where JobNo = @JobNo


  -- From here, send execution report and any error message if found

  -- If the operator is missing, emit an error message 
  -- and exit now to put error status in the SQL Agent job.
  
  Declare @email_Address sysname   -- to read email address of the operator
  
  select @email_Address = email_Address 
  from  Msdb..sysoperators 
  where name = @oper and enabled = 1
  
  If @@rowcount = 0
  Begin
    Raiserror (' The operator name supplied to the procedure Maint.DeleteOldBackups, must exist and be enabled in msdb..sysoperators ', 11, 1)
    return
  End

  Declare @EndOfCleanup datetime   
  set @EndOfCleanup = getdate()

  Exec yExecNLog.LogAndOrExec 
      @context = 'Maint.DeleteOldBackups'
    , @Info = 'End of backup cleanup'
    , @JobNo = @JobNo

  If @email_Address is NOT NULL 
    Exec yMaint.SendExecReports
      @email_Address = @email_Address
    , @command = @command
    , @MaintJobName = @MaintJobName
    , @StartOfMaint = @StartOfCleanup 
    , @JobNo = @JobNo   
    , @SendOnErrorOnly = @SendOnErrorOnly  -- 1 = Send email only when there is a error

End -- Maint.DeleteOldBackups
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMirroring.MirrorLoginSync'
GO
Create Procedure yMirroring.MirrorLoginSync
  @servername sysname
, @loginname sysname
, @type char(1)
, @password_hash varbinary(256)
, @sid varbinary(85)
, @policy_checked  nvarchar(3)
, @expiration_checked nvarchar(3)
, @deflanguage sysname
, @sysadmin int
, @securityadmin int
, @serveradmin int
, @setupadmin int
, @processadmin int
, @diskadmin int
, @dbcreator int
, @bulkadmin int
, @jobNo int = NULL
, @is_disabled int = 0

As
Begin
  declare @sql nvarchar(max)
  declare @loginExists int
  declare @password_hash_local varbinary(256)
  declare @sid_local varbinary(85) 
  declare @is_disabled_local int
  
  Set @loginExists = 0
  
  Select 
    @loginExists = 1
  , @password_hash_local = sl.password_hash
  , @sid_local = sp.sid
  , @is_disabled_local = sp.is_disabled
  From 
    sys.server_principals sp
    
    Left join
    sys.sql_logins sl
    on sp.name = sl.name
  Where sp.name = @loginname
              
  -- Id Login is the same with same SID and password we can skip this one
  If   @loginExists = 1
   AND @sid = @sid_local
   AND IsNull(@password_hash, 0x) = IsNull(@password_hash_local, 0x)
   AND @is_disabled_local = @is_disabled
   Return(0)
     
  Begin Try      
    -- If login already exists we drop it so we can recreate it with good password and good sid  
    If   @loginExists = 1
     AND (   @sid <> @sid_local
          Or IsNull(@password_hash, 0x) <> IsNull(@password_hash_local, 0x))
    Begin
      Set @sql = 'Drop Login [<loginname>]'
      
      Set @sql = REPLACE(@sql, '<loginname>', @loginname)
      Set @sql = REPLACE(@sql, '"', '''')
      
      Exec(@sql)
    End
        
    If (@type IN ( 'G', 'U'))
    Begin
      If left(@loginname, len(@servername+'\')) = @servername+'\' 
        -- essaie de le recréer local sur le nouveau serveur
        Set @loginname = Replace(@loginname, @servername+'\', convert(sysname, serverproperty('machinename'))+'\') 
          
      Set @sql = 
      '
      CREATE LOGIN [<loginname>] FROM WINDOWS WITH DEFAULT_LANGUAGE=<language>
      '    
    End
    Else
    Begin
      Set @sql = 
      '
      CREATE LOGIN [<loginname>] 
        WITH PASSWORD=<password> HASHED
           , SID=<sid>
           , CHECK_POLICY=<checkpolicy>
           , CHECK_EXPIRATION=<checkexpiration>
           , DEFAULT_LANGUAGE=<language>
      '          
    End

    -- If login has been disabled, disable it
    If @is_disabled_local = 0 AND @is_disabled = 1
    Begin
      Set @sql = 'ALTER Login [<loginname>] DISABLE; DENY CONNECT SQL TO [<loginname>];'
      
      Set @sql = REPLACE(@sql, '<loginname>', @loginname)
      Set @sql = REPLACE(@sql, '"', '''')
      
      Exec(@sql)
    End

    -- If login has been enabled, enable it
    If @is_disabled_local = 1 AND @is_disabled = 0
    Begin
      Set @sql = 'ALTER Login [<loginname>] ENABLE; GRANT CONNECT SQL TO [<loginname>];'
      
      Set @sql = REPLACE(@sql, '<loginname>', @loginname)
      Set @sql = REPLACE(@sql, '"', '''')
      
      Exec(@sql)
    End

    If @sysadmin       = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "sysadmin"'
    If @securityadmin  = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "securityadmin"'
    If @serveradmin    = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "serveradmin"'
    If @setupadmin     = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "setupadmin"'
    If @processadmin   = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "processadmin"'
    If @diskadmin      = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "diskadmin"'
    If @dbcreator      = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "dbcreator"'
    If @bulkadmin      = 1 Set @Sql = @sql + 'EXEC sp_addsrvrolemember "<loginname>", "bulkadmin"'

    Set @sql = REPLACE(@sql, '<loginname>', @loginname)
    Set @sql = REPLACE(@sql, '<password>', yUtl.ConvertToHexString(@password_hash))
    Set @sql = REPLACE(@sql, '<sid>', yUtl.ConvertToHexString(@sid))
    Set @sql = REPLACE(@sql, '<checkpolicy>', @policy_checked)
    Set @sql = REPLACE(@sql, '<checkexpiration>', @expiration_checked)
    Set @sql = REPLACE(@sql, '<language>', @deflanguage)
    Set @sql = REPLACE(@sql, '"', '''')
    
    Exec yExecNLog.LogAndOrExec 
        @context = 'yMirroring.MirrorLoginSync'
      , @sql = @sql  
      , @Info = 'Synchronizing accounts to mirror Server '
      , @JobNo = @JobNo
        
  End Try
  Begin Catch
  End Catch

End --yMirroring.MirrorLoginSync
GO
Create Procedure yMirroring.LaunchLoginSync 
  @MirrorServer sysname
, @JobNo int = null  
As
Begin

  declare @MirrorServerName sysname
  declare @sql nvarchar(max)
  declare @servername sysname
  declare @loginname sysname
  declare @type char(1)
  declare @password_hash varbinary(256)
  declare @sid varbinary(85)
  declare @policy_checked  nvarchar(3)
  declare @expiration_checked nvarchar(3)
  declare @deflanguage sysname
  declare @sysadmin int
  declare @securityadmin int
  declare @serveradmin int
  declare @setupadmin int
  declare @processadmin int
  declare @diskadmin int
  declare @dbcreator int
  declare @bulkadmin int    
  declare @is_disabled int
    
  Set NoCount On
  
  SELECT 
    p.name
  , Convert(sysname, serverproperty('machinename')) as servername
  , p.type
  , IsNull(sl.password_hash, 0x) As password_hash
  , p.sid
  , Case When sl.is_policy_checked = 1 Then 'ON' Else 'OFF' End As is_policy_checked
  , Case When sl.is_expiration_checked = 1 Then 'ON' Else 'OFF' End As is_expiration_checked
  , p.default_language_name
  , l.sysadmin
  , l.securityadmin
  , l.serveradmin
  , l.setupadmin
  , l.processadmin
  , l.diskadmin
  , l.dbcreator
  , l.bulkadmin
  , p.is_disabled
  INTO #Logins
  FROM 
    sys.server_principals p
   
    LEFT JOIN 
    sys.sql_logins sl
    ON sl.name = p.name 
    
    Left Join
    sys.syslogins l
    on l.sid = p.sid  
       
  WHERE p.type IN ( 'S', 'G', 'U' ) 
    AND p.name <> 'YourSQLDba'
    AND p.name <> 'SA'
    AND p.name Not Like 'AUTORITE NT\%'
    AND p.name Not Like 'NT SERVICE\%'
    AND p.name Not Like 'BUILTIN\Administra%'
    AND p.name Not Like '##Ms[_]Policy%##'
    
  CREATE UNIQUE CLUSTERED INDEX Logins_P ON #Logins (name)
      
  Set @MirrorServerName = ''
  
  While 1= 1
  Begin
  
    Select Top 1 @MirrorServerName=MirrorServerName 
    From Mirroring.TargetServer
    Where MirrorServerName > @MirrorServerName
      AND MirrorServerName = @MirrorServer
           
    If @@rowcount = 0
      break
      
    Set @loginname = ''
    
    While 1=1    
    Begin
      
      Select Top 1 
        @loginname = name
      , @servername = servername
      , @type = type
      , @password_hash = password_hash
      , @sid = sid
      , @policy_checked = is_policy_checked
      , @expiration_checked = is_expiration_checked
      , @deflanguage = default_language_name
      , @sysadmin = sysadmin
      , @securityadmin = securityadmin
      , @serveradmin = serveradmin
      , @setupadmin = setupadmin
      , @processadmin = processadmin
      , @diskadmin = diskadmin
      , @dbcreator = dbcreator
      , @bulkadmin = bulkadmin   
      , @is_disabled = is_disabled    
        
      From #Logins
      Where name > @loginname
      Order by name
    
      If @@rowcount = 0
        break
              
      Set @sql = 'Exec [<mirrorserver>].YourSqlDba.yMirroring.MirrorLoginSync @servername = "<servername>", @loginname = "<loginname>", @type = "<type>", @password_hash = <password_hash>, @sid = <sid>, @policy_checked = "<policy_checked>", @expiration_checked = "<expiration_checked>", @deflanguage = "<deflanguage>", @sysadmin = <sysadmin>, @securityadmin = <securityadmin>, @serveradmin = <serveradmin>, @setupadmin = <setupadmin>, @processadmin = <processadmin>, @diskadmin = <diskadmin>, @dbcreator = <dbcreator>, @bulkadmin = <bulkadmin>, @jobNo = NULL, @is_disabled=<is_disabled>'
      
      Set @sql = yExecNLog.Unindent_TSQL(@sql)
      Set @sql = REPLACE(@sql, '<mirrorserver>', @MirrorServerName)     
      Set @sql = REPLACE(@sql, '<servername>', @servername)
      Set @sql = REPLACE(@sql, '<loginname>', @loginname)
      Set @sql = REPLACE(@sql, '<type>', @type)
      Set @sql = REPLACE(@sql, '<password_hash>', yUtl.ConvertToHexString(@password_hash))
      Set @sql = REPLACE(@sql, '<sid>', yUtl.ConvertToHexString(@sid))
      Set @sql = REPLACE(@sql, '<policy_checked>', @policy_checked)
      Set @sql = REPLACE(@sql, '<expiration_checked>', @expiration_checked)
      Set @sql = REPLACE(@sql, '<deflanguage>', @deflanguage)
      Set @sql = REPLACE(@sql, '<sysadmin>', @sysadmin)
      Set @sql = REPLACE(@sql, '<securityadmin>', @securityadmin)
      Set @sql = REPLACE(@sql, '<serveradmin>', @serveradmin)
      Set @sql = REPLACE(@sql, '<setupadmin>', @setupadmin)
      Set @sql = REPLACE(@sql, '<processadmin>', @processadmin)
      Set @sql = REPLACE(@sql, '<diskadmin>', @diskadmin)
      Set @sql = REPLACE(@sql, '<dbcreator>', @dbcreator)
      Set @sql = REPLACE(@sql, '<bulkadmin>', @bulkadmin)
      Set @sql = REPLACE(@sql, '<is_disabled>',@is_disabled)
      Set @sql = REPLACE(@sql, '"', '''')


      Declare @Info nvarchar(max)
      Set @Info = 'Synchronizing account: "' + @loginname+'"'
      Exec yExecNLog.LogAndOrExec 
          @context = 'yMirroring.LaunchLoginSync'
        , @Info = @Info  
        , @sql = @sql
        , @jobNo = @jobno 
      
    End -- for each login
    
  End -- for each server
          
End -- yMirroring.LaunchLoginSync
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
go
Exec f$.DropObj 'yMirroring.ReportYourSqlDbaVersionOnTargetServers' 
GO
Create Procedure yMirroring.ReportYourSqlDbaVersionOnTargetServers
  @MirrorServer sysname 
, @LogToHistory int = 1
, @silent int = 0 
, @remoteVersion nvarchar(100) = NULL OUTPUT 
, @jobNo int = null
As
Begin
  set nocount on
  
  Declare @sql nvarchar(max)
  Declare @err nvarchar(max)
  Declare @Info nvarchar(max)
  
  -- Ensure that target servers are still in sys.servers, otherwise remove them
  If not exists
     (
     select * 
     from sys.servers S 
     Where S.name = @MirrorServer collate database_default
       And S.is_linked = 1
     )
  Begin   
    Set @remoteVersion = 'Server undefined'
    Set @Err = 'No linked server is defined under the name: ['+@MirrorServer+']'
    If @silent = 0 Print @Info
    If @LogToHistory = 1 And @silent = 0
    Begin
      Exec yExecNLog.LogAndOrExec 
        @jobNo = @jobNo
      , @context = 'yMirroring.ReportYourSqlDbaVersionOnTargetServers'
      , @YourSqlDbaNo = '021'
      , @Err = @err
      , @raiseError = 0
    End  
    Return  -- don't go further
  End
  
  
  -- Check if YourSQLDba is installed at remote
  Begin try
  Set @sql =
  '
  Declare @Exists Int
  Set @RemoteVersionInfo=""
  Select @exists = Dbid
  from Openquery ([<RemoteServer>], "select Db_Id(""YourSQLDba"") as DbId") as x
  If @Exists Is NULL
    Set @RemoteVersionInfo = "Remote YourSqlDba is missing"
  '

  Set @sql = REPLACE( @sql, '<RemoteServer>', @MirrorServer)
  Set @sql = REPLACE( @sql, '"', '''')
  Print @sql
  Exec sp_executeSql @sql, N'@LogToHistory int = 1, @remoteVersionInfo nvarchar(100) Output', @LogToHistory = @LogToHistory, @remoteVersionInfo = @remoteVersion Output
  If @RemoteVersion = 'Remote YourSqlDba is missing'
  Begin
    Set @err = 'YourSQLDba must be installed on ['+@MirrorServer+'] for mirroring purpose. Run YourSQLDba_InstallOrUpdateScript.sql on this server.'
    If @silent = 0 Print @Info
    If @LogToHistory = 1 And @silent = 0
    Begin
      Exec yExecNLog.LogAndOrExec 
        @jobNo = @jobNo
      , @context = 'yMirroring.ReportYourSqlDbaVersionOnTargetServers'
      , @YourSqlDbaNo = '021'
      , @Err = @Err
      , @raiseError = 0
    End  
    Return -- don't go further
  End
  End try
  Begin catch
    If ERROR_NUMBER () = 7416  Print 'Access to the remote server is denied because no login-mapping exists.'
    set @remoteVersion = 'no remote mapping exists'
    return
  End catch 

  Set @sql =
  '
  Declare @Exists Int
  Set @RemoteVersionInfo=""
  Select @exists = Objectid
  from Openquery ([<RemoteServer>], "select OBJECT_ID(""YourSQLDba.Install.versioninfo"") as ObjectId") as x

  If @exists IS NULL
    Set @RemoteVersionInfo = "Version before Install.VersionInfo"
  '
    
  Set @sql = REPLACE( @sql, '<RemoteServer>', @MirrorServer)
  Set @sql = REPLACE( @sql, '"', '''')
  Print @sql
  Exec sp_executeSql @sql, N'@LogToHistory int = 1, @remoteVersionInfo nvarchar(100) Output', @LogToHistory = @LogToHistory, @remoteVersionInfo = @remoteVersion Output
  If @RemoteVersion = 'Version before Install.VersionInfo'
  Begin
    Set @err = 'Versions of YourSQLDba on [' + @@servername + '] And ['+@MirrorServer+'] need to be the same for mirroring purpose. Re-run YourSQLDba_InstallOrUpdateScript.sql on both servers.'
    If @silent = 0 Print @Info
    If @LogToHistory = 1 And @silent = 0
    Begin
      Exec yExecNLog.LogAndOrExec 
        @jobNo = @jobNo
      , @context = 'yMirroring.ReportYourSqlDbaVersionOnTargetServers'
      , @YourSqlDbaNo = '021'
      , @err = @err
      , @raiseError = 0
    End  
    Return -- don't go further
  End
  
  Set @sql =
  '
  Declare @Exists Int
  Set @RemoteVersionInfo=""
  Select @RemoteVersionInfo = versionNumber
  from Openquery ([<RemoteServer>], "select versionNumber From YourSQLDba.Install.VersionInfo() F") as x
  '

  Set @sql = REPLACE( @sql, '<RemoteServer>', @MirrorServer)
  Set @sql = REPLACE( @sql, '"', '''')
  Print @sql
  Exec sp_executeSql @sql, N'@LogToHistory int = 1, @remoteVersionInfo nvarchar(100) Output', @LogToHistory = @LogToHistory, @remoteVersionInfo = @remoteVersion Output

  If (Select versionNumber From YourSQLDba.Install.VersionInfo()) <> @RemoteVersion
  Begin
    Set @err = 'Versions of YourSQLDba on [' + @@servername + '] And ['+@MirrorServer+'] need to be the same for mirroring purpose. Re-run YourSQLDba_InstallOrUpdateScript.sql on both servers.'
    If @silent = 0 Print @Info
    If @LogToHistory = 1 And @silent = 0
    Begin
      Exec yExecNLog.LogAndOrExec 
        @jobNo = @jobNo
      , @context = 'yMirroring.ReportYourSqlDbaVersionOnTargetServers'
      , @YourSqlDbaNo = '021'
      , @err = @err
      , @raiseError = 0
    End  
  End
End
go

--declare @DbName sysname, @DoBackup  char(1), @FullBackupPath nvarchar(512), @overwrite  int
--Select @DbName = 'LeDbName', @DoBackup = 'L', @FullBackupPath = 'c:\unedestin\', @overwrite = 1
--Select yMaint.MakeBackupCmd (@DbName, @DoBackup, @FullBackupPath, @overwrite)
--GO
-- ------------------------------------------------------------------------------
-- Proc for doing backup.  MUST BE CALLED from YourSqlDba_DoMaint because
-- many parameters are passed through jobMaintHistory record that match JobNo
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.Backups'

GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
CREATE proc yMaint.Backups
  @jobNo Int
as
Begin
  
  Set nocount On 

  declare @Info nvarchar(max)
  declare @DbName sysname           
  Declare @filename  nvarchar(512) 
    
  declare @sql nvarchar(max)    -- Sql Command
  Declare @sql2 nvarchar(max)
  Declare @FullRecoveryMode Int -- recovery mode of the database
  Declare @seq Int              -- row seq. in work tables
  Declare @ctx sysname          -- context id 

  Declare @email_Address sysname   
  declare @d datetime           -- start hour
  --declare @StartOfDay Datetime   
  declare @lockResult Int

  declare @errorN Int  -- return code for full backups
  declare @errorN_BkpPartielInit Int  -- return code for log backups
  declare @FailedBkpCnt Int -- failed backups count on a given database
  
  Declare @MustLogBackupToShrink int

  Declare @MaintJobName nVarchar(200)
  Declare @DoBackup nvarchar(5)
  Declare @DoFullBkp nvarchar(5)
  Declare @DoDiffBkp nvarchar(5)
  Declare @DoLogBkp nvarchar(5)
  Declare @TimeStampNamingForBackups Int
  Declare @FullBkpRetDays Int 
  Declare @LogBkpRetDays Int 
  Declare @NotifyMandatoryFullDbBkpBeforeLogBkp int 
  Declare @BkpLogsOnSameFile int 
  Declare @SpreadUpdStatRun int 
  Declare @SpreadCheckDb int
  Declare @FullBackupPath nvarchar(512) 
  Declare @LogBackupPath nvarchar(512) 
  Declare @ConsecutiveDaysOfFailedBackupsToPutDbOffline Int 
  Declare @IncDb nVARCHAR(max) 
  Declare @ExcDb nVARCHAR(max) 
  Declare @JobId uniqueidentifier 
  Declare @StepId Int 
  Declare @Language nvarchar(512)
  Declare @jobStart Datetime
  Declare @MirrorServer sysname
  Declare @BrokerDlgHandle uniqueidentifier
  Declare @FullBkExt nvarchar(7) 
  Declare @LogBkExt nvarchar(7) 
  Declare @err nvarchar(max)
  Declare @msg nvarchar(max)
  Declare @ReplaceSrcBkpPathToMatchingMirrorPath nvarchar(max) 
  Declare @ReplacePathsInDbFilenames nvarchar(max) 
  
  -- replace null by empty string
  Set @ReplaceSrcBkpPathToMatchingMirrorPath = ISNULL(@ReplaceSrcBkpPathToMatchingMirrorPath, '')
  Set @ReplacePathsInDbFilenames = ISNULL(@ReplacePathsInDbFilenames , '')
  
  create table #MustLogBackupToShrink (i int)

  Declare @DbTable table (dbname sysname, FullRecoveryMode int)
  Insert into @Dbtable select dbname, FullRecoveryMode from #Db

  Select 
    @MaintJobName = JobName 
  , @DoFullBkp = DoFullBkp
  , @DoLogBkp = DoLogBkp
  , @FullBkpRetDays = FullBkpRetDays
  , @TimeStampNamingForBackups = TimeStampNamingForBackups
  , @LogBkpRetDays = LogBkpRetDays
  , @NotifyMandatoryFullDbBkpBeforeLogBkp = NotifyMandatoryFullDbBkpBeforeLogBkp
  , @BkpLogsOnSameFile = BkpLogsOnSameFile
  , @FullBackupPath = yUtl.NormalizePath(FullBackupPath )
  , @LogBackupPath = yUtl.NormalizePath(LogBackupPath )
  , @FullBkExt = FullBkExt
  , @LogBkExt = LogBkExt
  , @ConsecutiveDaysOfFailedBackupsToPutDbOffline = ConsecutiveDaysOfFailedBackupsToPutDbOffline 
  , @IncDb = IncDb 
  , @ExcDb = ExcDb 
  , @jobStart = JobStart 
  , @MirrorServer = MirrorServer
  , @JobId = JobId
  , @StepId = StepId
  , @MirrorServer = MirrorServer
  , @ReplaceSrcBkpPathToMatchingMirrorPath = ReplaceSrcBkpPathToMatchingMirrorPath
  , @ReplacePathsInDbFilenames= ReplacePathsInDbFilenames
  , @DoDiffBkp = DoDiffBkp

  From Maint.JobHistory Where JobNo = @JobNo

  -- check if MirrorServer is still valid
  If ISNULL(@MirrorServer, '') <> ''
  Begin
    Declare @remoteVersion nvarchar(100)
    Exec yMirroring.ReportYourSqlDbaVersionOnTargetServers @jobNo = @jobNo, @MirrorServer = @MirrorServer, @LogToHistory = 1, @remoteVersion = @remoteVersion OUTPUT 
    If (select VersionNumber from Install.VersionInfo()) <> @remoteVersion
    Begin
      Set @MirrorServer = '' -- this disable restore to remote server
    end  
  End  
    
  -- clean-up entries for now inexistent (removed databases)
  Delete LB
  From
    Maint.JobLastBkpLocations LB
    LEFT JOIN
    master.sys.databases D
    ON LB.dbName = D.name COLLATE Database_default
  Where D.Name is NULL  
    And LB.keepTrace = 0

  If @DoFullBkp = 1 Set @DoBackup = 'F'
  If @DoDiffBkp = 1 Set @DoBackup = 'D'
  If @DoLogBkp = 1 Set @DoBackup = 'L'
  

  -- ==============================================================================
  -- Start of backup processing
  -- ==============================================================================

  -- Delete old full backups, only when full backup must be done

  Begin try
    -- FulBkpRet is the amount of day 0=today, none is done, 1=yesterday
    If @DoFullBkp = 1 And @FullBkpRetDays >= 0 -- no cleanup if < 0 or null
    Begin
      Exec Maint.DeleteOldBackups 
        @Path = @FullBackupPath
      , @IncDb = @IncDb 
      , @ExcDb = @ExcDb 
      , @BkpRetDays = @FullBkpRetDays
      , @RefDate = @jobStart
      , @extension = @FullBkExt
      , @BkpRetDaysForUnSelectedDb = NULL  -- Dont cleanup other backup files
      , @JobNo = @JobNo
    End  -- If
  End try
  Begin catch
    Set @msg = 'Error in deleting old full backups' 
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @jobNo
    , @context = 'yMaint.Backups'
    , @Info = @msg
    , @err = '?'
  End Catch

  -- Delete Log backups older than n days
  Begin try
    If (@DoLogBkp = 1 Or @DoFullBkp = 1) And @LogBkpRetDays >= 0 -- no cleanup if < 0 or null
    Begin

      Exec YourSQLDba.Maint.DeleteOldBackups 
        @Path = @LogBackupPath
      , @IncDb = @IncDb 
      , @ExcDb = @ExcDb 
      , @BkpRetDays = @LogBkpRetDays
      , @RefDate = @jobStart
      , @extension = @LogBkExt 
      , @BkpRetDaysForUnSelectedDb = NULL  -- Dont cleanup other backup files
      , @JobNo = @JobNo

      -- leave process to attempt backups, so failed backup count is going to increase
    End  -- If
  End try
  Begin catch
    Set @msg = 'Error in deleting old full backups' 
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @jobNo
    , @context = 'yMaint.Backups'
    , @Info = @msg
    , @err = '?'
  End Catch

  Begin Try

    -- Get the installation language of the SQL Server instance
    Exec yInstall.InstallationLanguage @Language output
    
  -- ===================================================================================== 
  -- main database backup loop by database
  -- ===================================================================================== 
    set @info =
        (
        Select 
          CONVERT(nvarchar(max), '|') 
        + case when d.FullRecoveryMode = 1 Then '(Full recovery)  ' Else '(Simple Recovery)' End 
        + d.dbName 
        + '|'
        from @DbTable D
        Order by d.dbname
        for XML PATH('')
        ) 
    Set @info = 'Database list obtained by @incBd and @ExecDb' + nchar(10) + REPLACE(@info, '|', nchar(10))    
    Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.Backups'
    , @Info = @info
    , @JobNo = @JobNo

    Set @DbName = ''
    While(1 = 1) -- T-SQL lacks simple Do Loop, work around...
    Begin
      -- this query get the next database (get the first when @dbname='')
      Select top 1 -- the first one next in alpha order (because top 1 + Where + Order by)
        @DbName = DbName
      From @DbTable
      Where DbName > @DbName -- next db in alpha order
      Order By DbName -- ... database name alpha order 

      -- Loop exit if last database processed (in alphabetic order)
      If @@rowcount = 0 
      Begin
        set @msg = @dbName + ' is the last database processed in the backups '
        Exec yExecNLog.LogAndOrExec 
          @context = 'yMaint.Backups'
        , @Info = @msg
        , @JobNo = @JobNo
          Break -- exit, no more db to process
      End

      If @DbName = 'MSDB' -- Skip over, because it is always backuped up at the end 
        Continue

      Set @msg = 'Checking if '+@dbname + ' must be processed...'
      Exec yExecNLog.LogAndOrExec 
        @context = 'yMaint.Backups'
      , @info = @msg
      , @JobNo = @JobNo

      If DatabasepropertyEx(@DbName, 'Status') <> 'ONLINE' -- if not online don't try to maintain
        Continue
      
      -- Validation block only, is log backup can be done?
      If @DoLogBkp = 1 -- log backups ?
      Begin
        -- If the database is read_only it is impossible to take log backup because
        -- first full backup is not recorded to the database, which void log backup
        -- And if the database is read-only what is the point to backup its log
        -- it is not supposed to grow
        
        If DATABASEPROPERTYEX(@DbName, 'Updateability') = 'READ_ONLY'
          Continue -- this Database don't move so no need to backup the log
          
        -- If the database is in simple recovery, it is impossible to do a save
        -- This situation is signaled if the user asked explicitely for it
        -- using @incDb.  This is for production database forgotten in simple recovery mode
        If DATABASEPROPERTYEX(@DbName, 'Recovery') NOT IN ('Full', 'BULK_LOGGED') 
        Begin
          -- User explicity asked for this database, and it is in simple recovery mode
          -- It must be told to him that log backups can be fulfilled
          If replace(replace(replace(@IncDb, ' ', ''), char(10), ''), char(13), '') <> ''   
          Begin

            -- User explicity stated by @incDb that he wants a log backup but that it can't done
            -- so signal it as an error.
            Set @msg = 'Forbidden log backup of ['+@DbName+'] because it is in simple recovery mode '

            Exec yExecNLog.LogAndOrExec 
              @context = 'yMaint.Backups'
            , @YourSqlDbaNo = '012' 
            , @Info = @Msg
            , @JobNo = @JobNo
            
          End -- if user asked for this database 
          Continue -- Jump to the next database

        End -- if simple recovery mode
        Else
        Begin -- full recovery mode
        
          -- if log backup can't be performed because no full backup is done
          -- let it know to the user, if the option is not turned off by the user
          If  Not Exists
               (
               select * 
               from sys.database_recovery_status 
               where database_id = db_id(@DbName) 
                 and last_log_backup_lsn is not null -- backup can't be done
               ) 
          Begin
            If @NotifyMandatoryFullDbBkpBeforeLogBkp = 1 
            Begin 
              Set @err = 'Log backup forbidden before doing a first full backup of ' 
                       + '['+@DbName+'] status is ' 
                       + CONVERT(nvarchar(100), DATABASEPROPERTYEX(@DbName, 'status') )

              Exec yExecNLog.LogAndOrExec 
                @context = 'yMaint.Backups'
              , @YourSqlDbaNo = '013' 
              , @Info = 'Log backups'
              , @err = @err
              , @JobNo = @JobNo

            End  
            Else
            Begin
              Set @err = 'Log backup forbidden before doing a first full backup of ' + '['+@DbName+']'

              Exec yExecNLog.LogAndOrExec 
                @context = 'yMaint.Backups'
              , @YourSqlDbaNo = '013' 
              , @Info = 'Log backups'
              , @err = @err
              , @JobNo = @JobNo
            End

            Continue -- jump to next one
          End -- if log backup can't be performed
        End
        
      End -- if log backups
               
      -- Get backup commande for full backup or log backup
      If @DoFullBkp = 1
      Begin
        Set @fileName = yMaint.MakeBackupFileName (@DbName, 'F', @FullBackupPath, @Language, @FullBkExt, @TimeStampNamingForBackups)  
        Set @ctx = 'Full backups'
      End  
      Else If @DoDiffBkp = 1
      Begin
        Set @fileName = yMaint.MakeBackupFileName (@DbName, 'D', @FullBackupPath, @Language, @FullBkExt, @TimeStampNamingForBackups)
        Set @ctx = 'Diff backups'
      End  
      Else
      Begin
        -- for log backups I want to continue to use the same file for the rest of the day
        -- usually it is there because the proc does an initial log backup with any full backup 
        
        Select 
          @fileName = lastLogBkpFile 
        From Maint.JobLastBkpLocations Where dbName = @DbName
                 
        If    @@rowcount = 0 
           Or @filename IS NULL -- backup done manualy
           Or @BkpLogsOnSameFile = 0  -- backup the log on a new file
        Begin
          Set @fileName = yMaint.MakeBackupFileName (@DbName, 'L', @LogBackupPath, @Language, @LogBkExt, @TimeStampNamingForBackups)  
        End 

        Set @Info = 'Log backups'

        Select -- get most up-to-date value for mirroring parameter
          @ReplaceSrcBkpPathToMatchingMirrorPath = ReplaceSrcBkpPathToMatchingMirrorPath 
        , @ReplacePathsInDbFilenames = ReplacePathsInDbFilenames
        , @MirrorServer = MirrorServer 
        From Maint.JobLastBkpLocations Where dbName = @DbName
      End  

      -- If there is row record for this database update it
      If Exists(Select * from Maint.JobLastBkpLocations Where dbName = @DbName)  
      Begin
        -- Mirror server change to reflect now from this backup.  Accept a mirror server only at full backup
        -- but if there is no or no more mirrorServer ensure to stop mirroring any time
        If @DoFullBkp = 1 Or @MirrorServer = '' Or @DoDiffBkp = 1
          Update Maint.JobLastBkpLocations 
          Set   mirrorServer = @MirrorServer
              , ReplaceSrcBkpPathToMatchingMirrorPath = @ReplaceSrcBkpPathToMatchingMirrorPath 
              , ReplacePathsInDbFilenames = @ReplacePathsInDbFilenames
              , lastFullBkpFile = Case When @DoFullBkp = 1 Then @FileName Else lastFullBkpFile End
              , lastDiffBkpFile = Case When @DoDiffBkp = 1 Then @FileName Else lastDiffBkpFile End
          Where dbName = @DbName 
      End  
      Else
        -- Insert new row records for this database, if it doesn't exists
        Insert into Maint.JobLastBkpLocations 
          (dbName, lastLogBkpFile, MirrorServer, lastFullBkpDate, ReplaceSrcBkpPathToMatchingMirrorPath, ReplacePathsInDbFilenames)
        Select   
          @DbName, Null, @MirrorServer, getdate(), @ReplaceSrcBkpPathToMatchingMirrorPath, @ReplacePathsInDbFilenames
        Where Not Exists(Select * from Maint.JobLastBkpLocations Where dbName = @DbName)

      Set @sql = yMaint.MakeBackupCmd
                 (
                   @DbName
                 , @DoBackup
                 , @fileName  
                 , Case When @DoBackup = 'F' Then 1 Else 0 End -- overwrite if full backup
                 , @MaintJobName 
                 )

      -- Launch full backup
      Exec yExecNLog.LogAndOrExec 
         @context = 'yMaint.backups'
       , @sql = @sql
       , @JobNo = @JobNo
       , @errorN = @errorN output
       
      If @DoFullBkp = 1
      Begin
        Exec Audit.ProcessExpiredDataAudits @dbName, @jobNo -- remove expired audits since we have them in backup
        Exec Audit.ProcessDataAuditsCleanup @dbname, @JobNo -- clean active audits sunce we have them in backup
      End

      -- Restore the backup to the mirror server (internally the procedure check is mirrorServer is in backup locations)
      Exec yMirroring.QueueRestoreToMirrorCmd
           @context = @ctx
         , @JobNo = @JobNo
         , @DbName = @DbName
         , @bkpTyp = @DoBackup
         , @fileName = @fileName
         , @MirrorServer = @MirrorServer
         , @ReplaceSrcBkpPathToMatchingMirrorPath = @ReplaceSrcBkpPathToMatchingMirrorPath
         , @ReplacePathsInDbFilenames = @ReplacePathsInDbFilenames
         , @BrokerDlgHandle = @BrokerDlgHandle OUT

      If @DoLogBkp = 1
      Begin
        -- shrink the log after backup (the procedure acts depending on the size)
        -- ShrinkLog may perform no shrink depending on internal database state (sys.databases.log_reuse_wait value)

        Set @sql2 =
        '        
        set nocount on 
        declare @MustLogBackupToShrink int
        Exec yMaint.ShrinkLog  @Db = "<DbName>", @JobNo=<JobNo>, @MustLogBackupToShrink = @MustLogBackupToShrink  output
        truncate table #MustLogBackupToShrink 
        insert into #MustLogBackupToShrink Values(@MustLogBackupToShrink)
        '
        Set @sql2 = replace(@sql2, '<DbName>', @DbName)
        Set @sql2 = replace(@sql2, '<JobNo>', convert(nvarchar, @JobNo))
        Set @sql2 = replace(@sql2, '"', '''')
        Exec yExecNLog.LogAndOrExec 
          @context = 'yMaint.backups'
        , @sql = @sql2
        , @Info = 'Log shrinking attempt'
        , @JobNo = @JobNo
        , @errorN = @errorN output
        
        If exists(select * from #MustLogBackupToShrink Where @MustLogBackupToShrink = 1)
          Exec yExecNLog.LogAndOrExec 
            @context = 'yMaint.backups'
          , @sql = @sql
          , @Info = 'Supplementary log backup to help log shrinking'
          , @JobNo = @JobNo
          , @errorN = @errorN output

      End

      -- If a full backup must be done, and if the database is in full recovery mode
      -- an initial log backup must be done
      
      If (@DoFullBkp = 1 or @DoDiffBkp = 1) And DATABASEPROPERTYEX(@DbName, 'Recovery') <> 'Simple'
      Begin
        Set @fileName = yMaint.MakeBackupFileName(@DbName, 'L', @LogBackupPath, @Language, @LogBkExt, @TimeStampNamingForBackups)  
        
        Set @sql = yMaint.MakeBackupCmd 
                   (
                     @DbName
                   , 'L' -- say explicitely full backup command
                   , @fileName
                   , 1
                   , @MaintJobName
                   )

        -- Launch first log backup that creates the file that will be used 
        -- to stored log backups usually for the rest of the days unless
        -- end-user launch Maint.SaveDbOnNewFileSet
        Exec yExecNLog.LogAndOrExec 
          @context = 'yMaint.backups'
        , @sql = @sql
        , @Info = 'Log backups (init)'
        , @JobNo = @JobNo
        , @errorN = @errorN_BkpPartielInit output

        -- Restore the backup to the mirror server if enabled
        Exec yMirroring.QueueRestoreToMirrorCmd
             @context = 'yMaint.backups (queue restore of log backup init)'
           , @JobNo = @JobNo
           , @DbName = @DbName
           , @bkpTyp = N'L'
           , @fileName = @fileName
           , @MirrorServer = @MirrorServer
           , @ReplaceSrcBkpPathToMatchingMirrorPath = @ReplaceSrcBkpPathToMatchingMirrorPath
           , @ReplacePathsInDbFilenames = @ReplacePathsInDbFilenames
           , @BrokerDlgHandle = @BrokerDlgHandle OUT
                              
        If @errorN_BkpPartielInit = 0 -- version 
        Begin
          Update Maint.JobLastBkpLocations   
          Set lastLogBkpFile = @filename
          Where dbName = @DbName 
          
          -- shrink the log after backup (the procedure acts depending on the size)
          -- Exec yMaint.ShrinkLog  @DbName, @JobNo
        End  
      End

      -- the decision to put a database offline only occurs on full db backup
      -- initial log backup error are taken into account at this time to
      If @DoFullBkp = 1 or @DoDiffBkp = 1
      Begin
        -- increment error count on any of the two backup types
        If @errorN <> 0 Or @errorN_BkpPartielInit <> 0  
        Begin
          Update Maint.JobLastBkpLocations   
          Set 
            FailedBkpCnt = FailedBkpCnt + 1
          , @FailedBkpCnt = FailedBkpCnt + 1
          , LastFullBkpDate = getdate() -- record the day when it happens again
          Where dbName = @DbName 
            And datediff(hh, lastFullBkpDate, getdate()) > 24 -- increment if it happens on different days
            And @DoDiffBkp <> 1

          If @FailedBkpCnt >= @ConsecutiveDaysOfFailedBackupsToPutDbOffline  -- if to many error put in offline mode
            Exec yMaint.PutDbOffline @DbName, @JobNo
        End  
        Else  
          Update Maint.JobLastBkpLocations   
          Set 
            FailedBkpCnt = 0
          , LastFullBkpDate = getdate() -- record the day when it succeed
          Where dbName = @DbName 
            And @DoDiffBkp <> 1
      End

    End -- Loop While (1 = 1) process each database selected

    -- a full backup of msdb always occurs even after log backup
    -- to get the most accurate up-to-date log history       
    Set @fileName = yMaint.MakeBackupFileName('MsDb', 'F', @FullBackupPath, @Language, @FullBkExt, @TimeStampNamingForBackups) 
    Set @sql = yMaint.MakeBackupCmd ('Msdb', 'F', @fileName, 1, '') 

    Exec yExecNLog.LogAndOrExec 
      @context = 'yMaint.backups'
    , @sql = @sql
    , @Info = 'Full Msdb backup to save the most up-to-date backup history'
    , @JobNo = @JobNo
    , @errorN = @errorN output
    
    -- If @BrokerDlgHandle is not null it tells us that we queued at least one restore to the mirror server
    -- so we send un message to indicate that mirror restore are over and we wait untill all the restore 
    -- are completed
    If @BrokerDlgHandle IS Not Null
    Begin
      Exec yExecNLog.LogAndOrExec 
        @context = 'yMaint.backups'
      , @Info = 'Waiting for mirror restore to complete'
      , @JobNo = @JobNo;

      -- Send de End message to the queue
      SEND ON CONVERSATION @BrokerDlgHandle
          MESSAGE TYPE [//YourSQLDba/MirrorRestore/End];
      
      Declare @RecvReqMsg xml
      Declare @RecvReqMsgName sysname
      Declare @TimeoutConsec int
      Set  @TimeoutConsec = 0
            
      While (1=1)
      Begin
      
        -- «WHERE conversation_handle = @BrokerDlgHandle» is very important so we receive only messages
        -- that were queued by this procedure.  
        Waitfor
        (
        RECEIVE TOP(1)
          @RecvReqMsg = convert(xml, message_body),
          @RecvReqMsgName = message_type_name
        FROM YourSqlDbaInitiatorQueueMirrorRestore
        WHERE conversation_handle = @BrokerDlgHandle
        ), timeout 600000 -- attends 10 minutes 60 sec * 10 min * 1000 millisec
        
        If @@ROWCOUNT = 0 -- may be a restore last more than 10 minutes, so 10 minutes without message
        Begin
          set @TimeoutConsec = @TimeoutConsec +1  -- but we won't wait forever
          If @TimeoutConsec > 18 -- 6 timeout = 1 hour, then max wait of 3 hour without messages
            Break
          Else  
            Continue
        End  
        Else 
          Set @TimeoutConsec = 0
          
        If @RecvReqMsgName = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
        Begin
          END CONVERSATION @BrokerDlgHandle
          BREAK
                    
        End --If @RecvReqMsgName = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'

        If @RecvReqMsgName = N'//YourSQLDba/MirrorRestore/Reply'
        Begin
          Set @JobNo = @RecvReqMsg.value('JobNo[1]', 'int')
          Set @seq = @RecvReqMsg.value('Seq[1]', 'int')
          Set @Info = 'Reply from queued mirror restore ' + nchar(10) + @RecvReqMsg.value('Info[1]', 'nvarchar(max)')
          
          Exec yExecNLog.LogAndOrExec 
             @context = 'yMaint.backups'
           , @Info = @info
           , @JobNo = @JobNo

        End --If @RecvReqMsgName = N'//YourSQLDba/MirrorRestore/Reply'        
      
      End --While RestoreEnded = 0    
      
    End --If @BrokerDlgHandle IS Not Null
    

  End try
  Begin catch
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @jobNo
    , @context = 'yMaint.Backups'
    , @Info = 'Error in yMaint.backups'
    , @err = '?'
  End Catch

End -- yMaint.Backups
GO
----------------------------------------------------------------------------------------------------------
-- Cleanup YourSqlDba tables for removed servers.
-- Install a the same YourSqlDba account on existing YourSqlDba mirror servers
-- and do a linked server login mapping impersonnation between the local account and the remote one.
-- Replicate local YourSqlDba account to to remote server.
-- Process is very safe, since nobody knows YourSqlDba account on both side
-- If multiple servers mirror their database to a single server, one must explicitely sets the same 
-- YourSqlDba account password on source servers, so the same account is going to be replicated 
-- by every participating server.
----------------------------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Exec f$.DropObj 'Mirroring.SetYourSqlDbaAccountForMirroring' 
GO
Create Procedure Mirroring.SetYourSqlDbaAccountForMirroring 
  @YourSqlDbaAccountForMirroringPwd Nvarchar(max) = NULL
as
Begin
  Set nocount on
  Declare @MirrorServerName sysname
  Declare @Sql nvarchar(max)
  declare @loginExists int
  declare @password_hash_local varbinary(256)
  declare @original_password_hash_local varbinary(256)
  declare @err int = 0
  declare @newPwd nvarchar(max) = NULL

  If @YourSqlDbaAccountForMirroringPwd = 'choose some password'
  Begin
    Raiserror ('Seriously, we don''t accept place holder ''choose some password'' as valid password, password rejected, please specify another one', 11, 1)
    Return
  End  

  -- remember actual password in hashed form
  Set @original_password_hash_local  = convert(varbinary(max), LOGINPROPERTY('YourSqlDba', 'PasswordHash'))

  -- get new password if specified or compute a new random value
  SET @newPwd = ISNULL(@YourSqlDbaAccountForMirroringPwd, replace(convert(nvarchar(max), newid(), 0)+convert(nvarchar(max), newid(), 0), '-', ''))
    
  Set @sql = 'Alter login YourSqlDba With password = '''+@NewPwd+''''
  Exec (@sql)
  -- Get new password hash for remote login, which is easy with login property.  
  Set @password_hash_local = convert(varbinary(max), LOGINPROPERTY('YourSqlDba', 'PasswordHash'));

  -- but if no password input was specified, set actual local password back to its original value
  -- now that we have the new password hash for remote login, otherwise this means that admin set also
  -- local password of YourSqlDba account with the same value
  If @YourSqlDbaAccountForMirroringPwd IS NULL
  Begin 
    Set @sql = 'Alter login YourSqlDba With password='+yUtl.ConvertToHexString(@Original_password_hash_Local)+' HASHED'
    Exec (@sql)
  End

  Set @MirrorServerName = ''
  While (1=1)
  Begin
    Select top 1 @MirrorServerName = MirrorServerName From Mirroring.TargetServer Where MirrorServerName > @MirrorServerName Order By MirrorServerName
    If @@ROWCOUNT = 0 Break

    -- Reinstall YourSqlDba mapping
    If Exists
       (
       Select *
       From 
         Sys.Servers S
         JOIN 
         Sys.linked_logins LL
         ON LL.server_id = S.server_id
         JOIN 
         Sys.server_principals P
         ON P.principal_id = LL.local_principal_id
       Where P.Name = 'YourSqlDba'
         And S.Name = @MirrorServerName 
         And S.is_linked = 1
       )
    Begin
      Print 'Drop previous YourSqlDba login mapping from ' + @MirrorServerName
      Exec Master.dbo.sp_Droplinkedsrvlogin @rmtsrvname = @MirrorServerName, @locallogin = 'YourSqlDba'
    End

    Print 'Reinstall YourSqlDba login mapping on ' + @MirrorServerName
    EXEC master.dbo.sp_addlinkedsrvlogin @rmtsrvname = @MirrorServerName, @locallogin = 'YourSqlDba', @rmtUser='YourSqlDba', @rmtpassword=@newPwd, @useself='False'
  
    -- Make YourSqlDba be the same with same account on other serveur.
     Set @sql = '
     Print "Synchronize YourSqlDba account on <mirrorserver>"
     Execute
     (
     "
     Use YourSqlDba
     Begin try
     -- proceed only if YourSqlDba database and its account exists
     Declare @currentSysAdmin sysname = SUSER_SNAME()
     If SUSER_SID(""YourSqlDba"") IS NOT NULL  AND DB_ID(""YourSqlDba"") IS NOT NULL
     Begin
       Exec (""alter authorization on database::yoursqldba to [""+@currentSysAdmin+""]"")
       Alter LOGIN YourSqlDba WITH PASSWORD=<password_hash> HASHED
       Exec (""alter authorization on database::yoursqldba to [YourSqlDba]"")
     End
     End try
     Begin catch
       Declare @msg nvarchar(max) = ""Msg ""+convert(varchar, error_number())+"" ""+Error_message()
       Raiserror (@Msg, 11, 1)
     End catch
     "
     ) At [<mirrorServer>]
     '
     Set @sql = REPLACE(@sql, '<mirrorserver>', @MirrorServerName)     
     Set @sql = REPLACE(@sql, '<password_hash>', yUtl.ConvertToHexString(@password_hash_Local))
     Set @sql = REPLACE(@sql, '"', '''')

     Begin try
       Print @sql
       Exec(@Sql)
     End Try
     Begin Catch
       Set @err = 1
       Declare @msg nvarchar(max) =  error_message ()
       Print @Msg
     End Catch
     
  End -- for each link server

  return @err

End -- Mirroring.SetYourSqlDbaAccountForMirroring
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
go
----------------------------------------------------------------------------------------------------------
-- Cleanup YourSqlDba tables for removed servers.
-- Check access of mirror servers through YourSqlDba account.  If a single one fails, email
-- and action to do set YourSqlDba password and set YourSqlDba account bridge to MirrorServer.
-- Return a success or status 
----------------------------------------------------------------------------------------------------------
Exec f$.DropObj 'yMirroring.CleanMirrorServerForMissingServerAndCheckServerAccessAsYourSqlDbaAccount' 
GO
Create Procedure yMirroring.CleanMirrorServerForMissingServerAndCheckServerAccessAsYourSqlDbaAccount
  @oper sysname = NULL
, @MirrorServer sysname = NULL
As
Begin
  Declare @err Int = 0

  -- cleanup inconsistent mirror references of the past
  Delete Mirroring.TargetServer Where isnull(MirrorServerName, '') = ''
  Delete M
  From Mirroring.TargetServer M
  Where Not Exists(Select * From Sys.Servers S Where S.Name = M.MirrorServerName Collate Database_Default And S.is_linked = 1)
  ;With 
    Vue_Update as
    (
    Select MirrorServer, ISNULL(TS.MirrorServerName, '') as ServerNameReplacement
    from 
      Maint.JobLastBkpLocations  JBL    -- cleanup mirroring.TargetServers, Maint.JobLastBkpLocations
      LEFT JOIN 
      Mirroring.TargetServer TS
      ON TS.MirrorServerName = JBL.MirrorServer
    Where JBL.MirrorServer <> ''
    )
  Update Vue_Update Set MirrorServer = ServerNameReplacement

  Declare @sql nvarchar(max)
  Declare @MirrorServerName sysname

  -- when called from maintenance SP, but there is no linked server under that name
  If ISNULL(@MirrorServer, '') <> '' And Not Exists (Select * From Sys.servers Where name = @MirrorServer And is_linked = 1)
    Set @err = 1

  -- imeprsonate YourSqlDba account to test connection
  Execute as login = 'yoursqldba'

  -- for each server, check remote access as YourSqlDba
  Set @MirrorServerName = ''
  declare @i int
  While (@err = 0) -- or break from the inside
  Begin
    Select top 1 @MirrorServerName = MirrorServerName From Mirroring.TargetServer Where MirrorServerName > @MirrorServerName Order By MirrorServerName
    If @@ROWCOUNT = 0 Break

    Begin try
    Set @sql =
    '
    Select @i=Dbid
    from Openquery ([<RemoteServer>], "select Db_Id(""Master"") as DbId") as x
    '
    Set @sql = REPLACE( @sql, '<RemoteServer>', @MirrorServerName)
    Set @sql = REPLACE( @sql, '"', '''')
    Exec sp_executeSql @sql, N'@i int output', @i output
    End try
    Begin catch
      print error_number()
      print error_message()
      Set @err = 1
      --7202
      --Could not find server <servername> in sys.servers. Verify that the correct server name was specified. If necessary, execute the stored procedure sp_addlinkedserver to add the server to sys.servers.

      --18456
      --Failure to open session with 'yoursqldba'.

      --7437
      --Linked servers cannot be used under impersonation without a mapping for the impersonated login.

    End catch 
  End -- While

  REVERT; -- leave YourSqlDba account persona

  If @err = 0 -- all mirror servers provide access through YourSqlDba account
    Return;

  -- try to auto-repair broken connections, which is possible only if currently 
  -- with an account that have sysadmin privileges that maps to a sysadmin account on each Mirror servers
  -- Must not be YourSqlDba, because we just tested it and it failed.
  If     SUSER_SNAME () <> 'YourSqlDba' 
     And IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME () )=1 
         -- Mirror server exists or not specified
     And (Exists (Select * From Sys.servers Where name = @MirrorServer And is_linked = 1) Or ISNULL(@MirrorServer, '') = '')
  Begin 
    Exec @err = Mirroring.SetYourSqlDbaAccountForMirroring    
    If @err = 0 
      Return 0;
  End  

  -- If here auto-repaired was not performed or couldn't be performed
  -- figures out who to notify if necessary
  Declare @email_address nvarchar(512) = NULL
  ;With 
    MostSusceptibleOperator as  
    (
    select email_Address
    from  Msdb..sysoperators 
    Where enabled = 1 And name = @oper -- if called from YourSqlDba_DoMaint

    UNION ALL

    SELECT top 1 S.recipients as email_Address  -- @oper is not specified, tries figure it out last message from YourSqlDba
    FROM msdb.dbo.sysmail_sentitems S
    Where s.subject like '%YourSqlDba%' And sent_status = 'Sent' And @oper is NULL
    )
  Select @email_address = email_Address
  From MostSusceptibleOperator 

  If @email_address IS NULL -- still can't figure out who to notify, nothing else to do
    Return

  Declare @body nvarchar(max)
  If ISNULL(@MirrorServer,'') <> '' -- if mirror server yoursqldba 
    If Exists (Select * From Sys.servers Where name = @MirrorServer And is_linked = 1) -- real server
      Set @body =  -- link couldn't be repaired send email to ask for it
      '
      Ensure that you are granted admin access to every remote linked server defined for your mirror servers
      and execute the following command on corresponding local servers:
        <br>
        <br>
        <b>Exec YourSQLDba.Mirroring.SetYourSqlDbaAccountForMirroring</b>
        <br>
      If the same MirrorServer has multiple source servers specify a common password on every of them:
        <br>
        <br>
        <b>Exec YourSQLDba.Mirroring.SetYourSqlDbaAccountForMirroring @SetYourSqlDbaAccountForMirroringPwd = ''choose some password''
        <br>
      '
    Else -- says that the parameter is invalid, @mirrorServer doesn't match linked server
      Set @body =
      '
      Specified @mirrorServer parameter doesn''t match with any linked servers names. Do Mirroring.Addserver
      to add the missing server or correct the parameter.
      '

  EXEC  Msdb.dbo.sp_send_dbmail
    @profile_name = 'YourSQLDba_EmailProfile'
  , @recipients = @email_Address
  , @importance = 'High'
  , @subject = 'YourSqlDba : Reset YourSqlDba account for MirrorServer or correct @mirrorServer parameter'
  , @body = @body
  , @body_format = 'HTML'

  Print 'Message sent to '+@email_Address
  Print 'Subject: ' + @body

  return 1
End
Go
-------------------------------------------------------------------------------------------
-- Maint Stored proc. that is scheduled for maintenance
-------------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.YourSqlDba_DoMaint'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
CREATE proc Maint.YourSqlDba_DoMaint
  @oper nvarchar(200) 
, @command nvarchar(200) = 'YourSqlDba_DoMaint' -- main command
, @MaintJobName nvarchar(200) = NULL  -- a name is =given to override mecanism that gets this information from Sql Agent job when NULL
, @DoInteg int = 0
, @DoUpdStats int = 0
, @DoReorg int = 0
, @DoBackup nvarchar(5) = ''
, @FullBackupPath nvarchar(512) = NULL 
, @LogBackupPath nvarchar(512) = NULL 
, @TimeStampNamingForBackups Int = 1 -- by default all backups are timestamped, when using deduplication tools, it is better to keep same backup name
, @FullBkExt nvarchar(7) = 'BAK' -- default backup extension for full backups
, @LogBkExt nvarchar(7) = 'TRN' -- default backup extension for transaction log backups
, @FullBkpRetDays Int = NULL -- by default no cleanup of full backups
, @LogBkpRetDays Int = NULL -- by default no cleanup of log backups
, @NotifyMandatoryFullDbBkpBeforeLogBkp int = 1
, @BkpLogsOnSameFile int = 1
, @SpreadUpdStatRun int = 7
, @SpreadCheckDb int = 7
, @ConsecutiveDaysOfFailedBackupsToPutDbOffline Int = 9999 -- max consecutives failure when of full backup and initial log backup
, @MirrorServer sysname = ''
, @ReplaceSrcBkpPathToMatchingMirrorPath nvarchar(max) = '' -- replaces on srcBkpPath to match corresponding path from mirror
, @ReplacePathsInDbFilenames nvarchar(max) = '' -- replaces in db files names to restore
, @IncDb nVARCHAR(max) = '' -- @IncDb : See comments later for further explanations
, @ExcDb nVARCHAR(max) = '' -- @ExcDb : See comments later for further explanations
, @ExcDbFromPolicy_CheckFullRecoveryModel nVARCHAR(max) = '' -- @ExcDbFromPolicy_CheckFullRecoveryModel : 
                                                             -- See comments later for further explanations
--, @JobId UniqueIdentifier = NULL -- job id of SQL Server Agent Job that launched the job
--, @StepId Int = NULL -- stepid of SQL Server Agent Jobstep  that launched the job
as
Begin
  
  Set nocount On 

  declare @sql nvarchar(max)       -- SQL query 

  Declare @email_Address sysname   -- to read email address of the operator
  declare @StartOfMaint datetime   -- when maintenance started
  declare @JobNo Int               -- job number
  declare @SendOnErrorOnly Int     -- when to send and error message
  declare @lockResult Int
  Declare @SqlBinRoot nvarchar(512)
  Declare @pathBkp nvarchar(512)
  Declare @JobId UniqueIdentifier  -- job id of SQL Server Agent Job that launched the job
  Declare @StepId Int              -- stepid of SQL Server Agent Jobstep  that launched the job

  -- alter admin when a valid linked server is specified, that this one or another needs a YourSqlDba password account reset
  If ISNULL(@MirrorServer, '') <> ''
  Begin
    Declare @rc Int
    Exec @rc = yMirroring.CleanMirrorServerForMissingServerAndCheckServerAccessAsYourSqlDbaAccount @oper=@oper, @MirrorServer=@MirrorServer
    If @rc <> 0
    Begin
      Raiserror ('YourSqlDba account must be reset manually, check YourSqlDba e-mail', 11, 1);
      Return
    End
  End

  Exec Install.PrintVersionInfo

  Set @ReplacePathsInDbFilenames = replace(replace(Isnull(@ReplacePathsInDbFileNames, ''), nchar(10), ''), nchar(13), '')
  Set @ReplaceSrcBkpPathToMatchingMirrorPath = replace(replace(Isnull(@ReplaceSrcBkpPathToMatchingMirrorPath , ''), nchar(10), ''), nchar(13), '')

  If @ReplaceSrcBkpPathToMatchingMirrorPath<> '' 
  Begin
    If charindex('>', @ReplaceSrcBkpPathToMatchingMirrorPath) = 0 
    Begin
      Raiserror ('Parameter @ReplaceSrcBkpPathToMatchingMirrorPath content must be separated by a ''>'' char between the search and the replace expression', 11, 1)
      return (1)
    End

    If right(@ReplaceSrcBkpPathToMatchingMirrorPath,1) <> '|' 
    Begin
      Raiserror ('Parameter @ReplaceSrcBkpPathToMatchingMirrorPath content must be ended by a pipe char ''|'' ', 11, 1)
      return (1)
    End
  End
  
  If @ReplacePathsInDbFilenames <> '' 
  Begin
    If charindex('>', @ReplacePathsInDbFileNames) = 0 
    Begin
      Raiserror ('Parameter @ReplacePathsInDbFileNames content must be separated by a ''>'' char between the search and the replace expression', 11, 1)
      return (1)
    End

    If right(@ReplacePathsInDbFileNames,1) <> '|' 
    Begin
      Raiserror ('Parameter @ReplacePathsInDbFileNames content must be ended by a pipe char ''|'' ', 11, 1)
      return (1)
    End
  End

  Set @FullBackupPath = yUtl.NormalizePath(@FullBackupPath)
  Set @LogBackupPath = yUtl.NormalizePath(@LogBackupPath)

  If @doBackup = 'C' Set @doBackup = 'F' -- translate 'C' = complete to 'F' = Full
  If @doBackup = 'P' Set @doBackup = 'L' -- translate 'P' = complete to 'L' = Log

  exec master.dbo.xp_instance_regread 
    N'HKEY_LOCAL_MACHINE'
  , N'Software\Microsoft\MSSQLServer\Setup'
  , N'SqlBinRoot'
  , @SqlBinRoot OUTPUT
  , 'no_output'

  exec master.dbo.xp_instance_regread 
    N'HKEY_LOCAL_MACHINE'
  , N'Software\Microsoft\MSSQLServer\MSSQLServer'
  , N'DefaultData'
  , @pathBkp OUTPUT
  , 'no_output'

  -- remind backup directory used, very useful when it comes to restore
  If @FullBackupPath IS NOT NULL and @FullBackupPath <> @pathBkp And (@DoBackup IN ('F','D'))
  Begin
    Declare @tmp nvarchar(512) 
    Set @tmp = @FullBackupPath
    If right(@tmp, 1) = '\' Set @tmp = stuff(@tmp, len(@tmp), 1, '') 
    EXEC xp_instance_regwrite 
      N'HKEY_LOCAL_MACHINE'
    , N'Software\Microsoft\MSSQLServer\MSSQLServer'
    , N'BackupDirectory'
    , REG_SZ
    , @tmp
  End
  
    -- use to timestamp filename
  set @StartOfMaint = getdate()

    -- Remove trace of backup location for databases no longer there
  Delete LB
  From
    Maint.JobLastBkpLocations LB
    LEFT JOIN
    master.sys.databases D
    ON LB.dbName = D.name COLLATE Database_default
  Where D.Name is NULL  
    And LB.keepTrace = 0
  
  If @FullBackupPath IS NULL Or @LogBackupPath IS NULL 
  Begin
    If @DoBackup IN ('F', 'L', 'D')
    Begin
      Raiserror ('Specify @FullBackupPath and/or @LogBackupPath to the procedure ', 11, 1)
      return
    End  
  End

  -- Error message if operator is missing, exit now to let error status in Sql agent job
  
  select @email_Address = email_Address 
  from  Msdb..sysoperators 
  where name = @oper and enabled = 1
  
  If @@rowcount = 0
  Begin
    Raiserror (' A valid operator name must be supplied to the procedure', 11, 1)
    return
  End

  -- Advise user that best practices are not followed
  If @DoBackup <> 'L'
    Exec PerfMon.ReportIgnoredBestPractices @email_Address = @email_Address 

  If @DoInteg = 1 Or @DoUpdStats = 1 Or @DoReorg = 1 Or (@DoBackup IN ('F','D'))
  Begin

    -- Warns it this version of YourSqlDba is quite Old   
    If GETDATE() > yInstall.NextUpdateTime()  And datepart(dd, getdate()) = 1  -- just do it once a month
    Begin
      declare @msgBody nvarchar(max)
      declare @subject nvarchar(max)
   	  declare @version nvarchar(20)
	     Select @version = VersionNumber From Install.VersionInfo()

      If CONVERT(nvarchar(20), SERVERPROPERTY('LCID')) <> '1036'
      Begin 
        set @subject = yInstall.DoubleLastSpaceInFirst78Colums ('YourSqlDba '+@Version+' reminder.  Time to check for the free newer YourSqlDba version at YourSqlDba.codeplex.com')
        Set @msgBody =
        '
        This message is to remind you to get the latest and most reliable YourSqlDba code for Sql instance: <ServerInstance>.
        <br>
        Applying latest version get rid of this monthly reminder.
        <br>
        Update is very easy. Just get the latest script by cliking on "Download" button at  
        <a href="http://YourSqlDba.CodePlex.Com">http://YourSqlDba.CodePlex.Com</a>, then open it and and run it.
        <br>
        Actually this project is subject to frequent improvments as the support of our large user community help us to find many uses cases. 
        If you want to keep up with new releases, we recommend to register as a codeplex user, log in, 
        and from download pane click on "get email notifications" or register to the projet RSS feed.
        <br>
        '
      End
      Else
      Begin 
        set @subject = yInstall.DoubleLastSpaceInFirst78Colums ('YourSqlDba '+@Version+' Rappel: Il est temps de vérifier la disponiblité d''une version plus récente de YourSqlDba à YourSqlDba.codeplex.com')
        Set @msgBody =
        '
        Ce message a pour but de vous rappeller de récupérer la version la plus récente de YourSqlDba pour l''instance: <ServerInstance>.
        <br>
        L''application de la dernière version fait disparaître ce message.
        <br>
        <br>
        La mise à jour est très simple. Obtenez le script en cliquant sur le bouton "Donwload" à 
        <a href="http://YourSqlDba.CodePlex.Com">http://YourSqlDba.CodePlex.Com</a> et puis ouvrez le et exécutez le.
        <br>
        <br>
        Ce projet fait l''objet d''améliorations fréquentes compte tenu que le support de notre grande communauté d''utilisateurs nous aide à découvrir beaucoup de cas d''utilisation.
        Si vous voulez demeurer à jour avec les nouvelles versions, nous vous recommandons de vous enregistrer comme usager codeplex, vous connecter, 
        et à partir de la section download cliquer sur "get email notifications" or vous abonner au fil RSS du projet.
        <br>
        '
      End

      Set @msgBody  = replace(@msgBody, '<ServerInstance>', convert(sysname, serverproperty('ServerName')))

      Set @msgBody  = replace(@msgBody, '<ServerInstance>', convert(sysname, serverproperty('ServerName')))
    
      EXEC  Msdb.dbo.sp_send_dbmail
        @profile_name = 'YourSQLDba_EmailProfile'
      , @recipients = @email_Address
      , @importance = 'Normal' 
      , @subject = @subject
      , @body = @msgBody 
      , @body_format = 'HTML'
    End

	   Set @SendOnErrorOnly = 0

    -- for all maintenance job execpt log backup alone we log a new job
    exec yExecNLog.AddJobEntry 
      @jobName = @MaintJobName
    , @JobNo = @JobNo output -- new or actual job

    Exec yExecNLog.LogAndOrExec 
      @context = 'Maint.YourSqlDba_DoMaint'
    , @Info = 'Beginning of job'
    , @JobNo = @JobNo


    --Exec yExecNLog.LogAndOrExec -- test logging mecanism on severe errord that does connexion lost (severity 20 and above)
    --  @context = 'Maint.YourSqlDba_DoMaint'
    --, @Info = 'Test fatal err'
    --, @JobNo = @JobNo
    --, @sql = 'raiserror (''test err fatale'', 25, 1) with log '    

    -- ==============================================================================
    -- Cleanup backup history, and log cleanup
    -- ==============================================================================
    exec yMaint.LogCleanup @JobNo
    Delete From Maint.JobHistoryAggregateLogBkp -- force a new log history job aggregation for log backups
  End  
  Else 
    Set @SendOnErrorOnly = 1

  -- log viewer has a poor display of job history. It supresses line feeds and truncate output
  -- we do prints of this message only here, because this is only here that we have the jobNo value
  -- we try to space out text to make it more readable.
  Print space(600)+'If an error is reported for this job, run the following EXEC command in a query window:'+
        space(256)+'YOURSQLDBA.MAINT.ShowHistoryErrors ' + convert(nvarchar, @jobNo) + 
        space(256)+' -- '

--  Begin try   

  -- avoid easy mistake (a narrow space between 2 quotes)
  Set @DoBackup = replace(@DoBackup, ' ', '') 

  -- try to keep same job, if it is only a log backup
  If @DoBackup = 'L'  And @DoInteg = 0 And @DoReorg = 0 And @DoUpdStats = 0 
  Begin
    -- Create a new job entry in the job history table, get jobId and stepId if ran from Job
    exec yExecNLog.IfSqlAgentJobGetJobIdAndStepId @jobId output, @stepId output
    
    Set @JobNo = NULL
    Select @JobNo = JobNo 
    From Maint.JobHistoryAggregateLogBkp 
    Where JobId = @JobId And StepId = @StepId
      
    If @JobNo is NULL
    Begin
      exec yExecNLog.AddJobEntry 
        @jobName = @MaintJobName
      , @JobNo = @JobNo output -- new or actual job

      Update Maint.JobHistory 
      Set 
        DoInteg = 0
      , DoUpdStats = 0
      , DoReorg = 0
      , DoFullBkp = 0
      , DoDiffBkp = 0
      , DoLogBkp = 1
      , JobStart = getdate()
      , JobEnd =  getdate()
      , IncDb = @IncDb
      , ExcDb = @ExcDb
      , ExcDbFromPolicy_CheckFullRecoveryModel = @ExcDbFromPolicy_CheckFullRecoveryModel
      , TimeStampNamingForBackups = @TimeStampNamingForBackups 
      , FullBkpRetDays = @FullBkpRetDays
      , LogBkpRetDays = @LogBkpRetDays
      , NotifyMandatoryFullDbBkpBeforeLogBkp = @NotifyMandatoryFullDbBkpBeforeLogBkp
      , SpreadUpdStatRun = @SpreadUpdStatRun
      , SpreadCheckDb = @SpreadCheckDb
      , FullBackupPath = @FullBackupPath
      , LogBackupPath = @LogBackupPath
      , ConsecutiveDaysOfFailedBackupsToPutDbOffline = @ConsecutiveDaysOfFailedBackupsToPutDbOffline
      , MirrorServer = @MirrorServer
      , ReplaceSrcBkpPathToMatchingMirrorPath = @ReplaceSrcBkpPathToMatchingMirrorPath
      , ReplacePathsInDbFileNames = @ReplacePathsInDbFileNames
      , JobId = @JobId
      , StepId = @StepId
      , BkpLogsOnSameFile = @BkpLogsOnSameFile
      , FullBkExt = @FullBkExt
      , LogBkExt = @LogBkExt
      Where JobNo = @JobNo
      
      Insert into Maint.JobHistoryAggregateLogBkp (JobNo, JobId, StepId) 
      Values (@JobNo, @JobId, @StepId)
      -- for a new adHoc action cluster log
    End  
  End

  -- When job is something else than just log backup, record a new entry, otherwise if all params
  -- specific to log backups are the same reuse the same job entry
  If @DoInteg = 1 Or @DoReorg = 1 Or @DoUpdStats = 1 Or @DoBackup = 'F' OR @DoBackup = 'D'  Or @JobNo is NULL
  Or Exists  
     (
     Select * 
     from 
     Maint.JobHistory j
     Where   
         j.JobNo = @JobNo 
     And j.BkpLogsOnSameFile <> @BkpLogsOnSameFile
     )  
  Begin

    -- recover job and step id 
    Select @JobId = jobId, @Stepid = stepId 
    from Maint.JobHistory  Where jobNo = @jobNo

    Update Maint.JobHistory 
    Set 
      DoInteg = @DoInteg
    , DoUpdStats = @DoUpdStats
    , DoReorg = @DoReorg
    , DoFullBkp = Case when @DoBackup = 'F' Then 1 Else 0 End -- DoFullBkp
    , DoLogBkp = Case when @DoBackup = 'L' Then 1 Else 0 End -- DoLogBkp
    , DoDiffBkp = Case when @DoBackup = 'D' Then 1 Else 0 End -- DoDiffBkp
    , JobStart = getdate()
    , JobEnd =  getdate()
    , IncDb = @IncDb
    , ExcDb = @ExcDb
    , ExcDbFromPolicy_CheckFullRecoveryModel = @ExcDbFromPolicy_CheckFullRecoveryModel
    , TimeStampNamingForBackups = @TimeStampNamingForBackups
    , FullBkpRetDays = @FullBkpRetDays
    , LogBkpRetDays = @LogBkpRetDays
    , NotifyMandatoryFullDbBkpBeforeLogBkp = @NotifyMandatoryFullDbBkpBeforeLogBkp
    , SpreadUpdStatRun = @SpreadUpdStatRun
    , SpreadCheckDb = @SpreadCheckDb
    , FullBackupPath = @FullBackupPath
    , LogBackupPath = @LogBackupPath
    , ConsecutiveDaysOfFailedBackupsToPutDbOffline = @ConsecutiveDaysOfFailedBackupsToPutDbOffline
    , MirrorServer = @MirrorServer
    , ReplaceSrcBkpPathToMatchingMirrorPath = @ReplaceSrcBkpPathToMatchingMirrorPath
    , ReplacePathsInDbFileNames = @ReplacePathsInDbFileNames
    , JobId = @JobId
    , StepId = @StepId
    , BkpLogsOnSameFile = @BkpLogsOnSameFile
    , FullBkExt = @FullBkExt
    , LogBkExt = @LogBkExt
    Where JobNo = @JobNo
  
  End
    
  -- add '\' to path name just in case it is missing

  If right(@FullBackupPath,1)<> '\' Set @FullBackupPath = @FullBackupPath + '\'
  If right(@LogBackupPath,1)<> '\' Set @LogBackupPath = @LogBackupPath + '\'

  -- Record all databases online, and if they are in full recovery mode or not (log backup allowed or not)
  -- The function udf_YourSQLDba_ApplyFilterDb apply filter parameters on this list 
  Create table #Db
  (
    DbName sysname primary key clustered 
  , DbOwner sysname
  , FullRecoveryMode int -- If = 1 log backup allowed
  , cmptLevel tinyInt
  )
  Insert into #Db
  Select * 
  from yUtl.YourSQLDba_ApplyFilterDb (@IncDb, @ExcDb)
  Where DatabasepropertyEx(DbName, 'Status') = 'Online' -- Avoid db that can't be processed
  
  -- remove snapshot database from the list
  Delete Db
  From #Db Db
  Where Exists(Select * From sys.databases d Where d.name = db.DbName and source_database_Id is not null)
  
  -- ==============================================================================
  -- perform integrity tests or not
  -- ==============================================================================
  If @DoInteg = 1
    Exec yMaint.IntegrityTesting @jobNo, @SpreadCheckDb

  -- ==============================================================================
  -- perform Update stat
  -- ==============================================================================
  If @DoUpdStats = 1
    Exec yMaint.UpdateStats @jobNo, @SpreadUpdStatRun
  
  -- ==============================================================================
  -- Reorganize index
  -- ==============================================================================
  If @DoReorg = 1
    Exec yMaint.ReorganizeOnlyWhatNeedToBe @jobNo

  -- ==============================================================================
  -- backup start
  -- ==============================================================================
    
  -- on complete backups suppress old files just before backup start
  
  If @DoBackup IN ('F', 'L', 'D')
  Begin
    Exec yMaint.backups @jobNo
  End -- If @DoBackup  
  
  Update Maint.JobHistory 
  Set JobEnd = Getdate()
  Where JobNo = @JobNo

  -- If backups are to be mirrored than we Launch a login synchronisation on the mirror server
  If isnull(@MirrorServer, '') <> ''
    And (@DoBackup = 'F' Or @DoBackup = 'D')
    Exec yMirroring.LaunchLoginSync @MirrorServer = @MirrorServer, @JobNo = @JobNo
    
  -- Check for databases that are in SIMPLE recovery mode and not excluded form this policy
  -- with the @ExcDbFromPolicy_CheckFullRecoveryModel parameter
  If @DoBackup = 'F' Or @DoBackup = 'D'
  Begin
    Exec yMaint.CheckFullRecoveryModelPolicy @jobNo, @IncDb, @ExcDb, @ExcDbFromPolicy_CheckFullRecoveryModel
  End

-- From here send execution report and any error message if found
  Exec yExecNLog.LogAndOrExec 
    @context = 'Maint.YourSqlDba_DoMaint'
  , @Info = 'End of maintenance'
  , @JobNo = @JobNo

  If @email_Address is NOT NULL
    Exec yMaint.SendExecReports
      @email_Address = @email_Address
    , @command = @command
    , @MaintJobName = @MaintJobName
    , @StartOfMaint = @StartOfMaint 
    , @JobNo = @JobNo   
    , @SendOnErrorOnly = @SendOnErrorOnly

End -- Maint.YourSqlDba_DoMaint
GO
-- ------------------------------------------------------------------------------
-- Function that get path only from complete file path
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUtl.GetPathFromName'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create function yUtl.GetPathFromName
(
  @pathAndFileName nvarchar(512)
)
returns nvarchar(max)
as
Begin

  Declare @filename  nvarchar(512)
  Declare @rPathAndFileName nvarchar(512)
  
  Set @rPathAndFileName = Reverse (@PathAndFileName)

  Set @filename = Reverse (Stuff(@rPathAndFileName, 1, charindex('\', @rPathAndFileName)-1, '')) 
      
  Return (@filename)
  
End -- yUtl.GetPathFromName

--select yUtl.GetPathFromName ('c:\backup\sub\toto.bak') -- some testing
--select yUtl.GetPathFromName (NULL) -- some testing
GO
GRANT CONNECT TO guest;
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.SaveDbOnNewFileSet'
GO
create proc Maint.SaveDbOnNewFileSet 
  @DbName nvarchar(128)
, @FullBackupPath nvarchar(512) = null
, @LogBackupPath nvarchar(512) = null
, @oper nvarchar(128) = null
, @MirrorServer sysname = ''
, @ReplaceSrcBkpPathToMatchingMirrorPath nvarchar(max) = NULL
, @ReplacePathsInDbFileNames nvarchar(max) = NULL
WITH execute as Self
as 
Begin
  Declare @command nvarchar(200) Set @command = 'SaveDbOnNewFileSet' -- main command
  Declare @nomTache nvarchar(512) 
  Declare @allowed int
  Declare @sql nvarchar(max)

  set @nomTache = 'SaveDbOnNewFileSet  of ' + @DbName

  Set @FullBackupPath = yUtl.NormalizePath(@FullBackupPath)
  Set @LogBackupPath = yUtl.NormalizePath(@LogBackupPath)

  -- Check backup permissions with original login
  EXECUTE AS LOGIN = ORIGINAL_LOGIN();

  Set @sql = 
  N'
  Use [<DbName>]
  Set @allowed = 0
  Declare @username sysname;   Set @username = USER_NAME()
  Declare @loginName sysname;  Set @loginName = SUSER_NAME()
  Declare @DbName sysname;     Set @DbName = db_name()

  If @username <> @loginName Set @username = @loginName + ":" + @username

  If   IS_MEMBER ("db_owner") = 1
    OR IS_MEMBER ("db_backupoperator") = 1 
    Or (
       select count(*)
       from [<DbName>].sys.database_permissions 
       where class_desc = "DATABASE" 
         and grantee_principal_id = USER_ID()
         And permission_name IN ("BACKUP DATABASE", "BACKUP LOG")
       ) = 2
    Print "User "+ @username +" autorized to do backup"
  Else
  Begin
    Raiserror ("User [%s] is not granted required rigths to full backups [%s]!", 11, 1, @username, @DbName)
    Return
  End  
  Set @allowed = 1
  '
  Set @sql = replace (@sql, '"', '''')
  Set @sql = replace (@sql, '<DbName>', @DbName)
  --print @sql
  Exec sp_ExecuteSql @sql, N'@allowed int output', @allowed output

  If @allowed = 0
  Begin
    Return
  End

  -- Reset sp impersonation to proceed with backup
  REVERT

  If not exists(Select * from master.sys.databases where name = @DbName)
  Begin
    Raiserror ('Database [%s] doesn''t exists !', 11, 1, @DbName)
    Return 
  End

  If @FullBackupPath is NULL 
    Select @FullBackupPath = yUtl.GetPathFromName(lastFullBkpFile)
    From Maint.JobLastBkpLocations
    Where dbName = @DbName
    
  If @FullBackupPath IS NULL -- toujours null
  Begin
    raiserror('No maintenance done yet on this database, parameter @FullBackupPath is then mandatory',11,1)
    return 
  End 

  If @LogBackupPath is NULL 
    Select @LogBackupPath = yUtl.GetPathFromName(lastLogBkpFile)
    From Maint.JobLastBkpLocations
    Where dbName = @DbName

  If @LogBackupPath IS NULL -- toujours null
  Begin
    If DatabasePropertyEx(@DbName, 'Recovery') = 'Simple'
      Set @LogBackupPath = @FullBackupPath
    Else  
    Begin
      raiserror('No maintenance done yet on this database, parameter @LogBackupPath is then mandatory',11,1)
      return 
    End  
  End 

  If isnull(@MirrorServer, '') = ''
    Select 
      @MirrorServer = MirrorServer
    , @ReplaceSrcBkpPathToMatchingMirrorPath = ReplaceSrcBkpPathToMatchingMirrorPath
    , @ReplacePathsInDbFileNames = ReplacePathsInDbFilenames
    From Maint.JobLastBkpLocations
    Where dbName = @DbName

  Set @oper = isnull(@oper, 'YourSQLDba_Operator')
  Exec Maint.YourSqlDba_DoMaint
    @oper = @oper
  , @command = @command
  , @MaintJobName = @nomTache
  , @DoBackup = 'F'
  , @FullBackupPath = @FullBackupPath
  , @LogBackupPath = @LogBackupPath
  , @IncDb = @DbName
  , @ConsecutiveDaysOfFailedBackupsToPutDbOffline = 9999  -- doesn't apply here
  , @MirrorServer = @MirrorServer
  , @ReplaceSrcBkpPathToMatchingMirrorPath = @ReplaceSrcBkpPathToMatchingMirrorPath
  , @ReplacePathsInDbFileNames = @ReplacePathsInDbFileNames
  , @ExcDbFromPolicy_CheckFullRecoveryModel = '%'

End -- Maint.SaveDbOnNewFileSet
GO
Exec f$.DropObj 'Maint.SaveDbCopyOnly'
GO

Create proc Maint.SaveDbCopyOnly 
  @DbName nvarchar(512)
, @PathAndFilename nvarchar(512) -- complete file name and path must be specified
, @errorN int = 0 output
With Execute as Self
As 
Begin
  Declare @sql nvarchar(max)
  Declare @cmd nvarchar(1000)

  Set nocount on

  -- Exécuter backup with initial login
  
  EXECUTE AS LOGIN = ORIGINAL_LOGIN();

  Print '----------------------------------------------------------'
  Print 'Saving Of ' + @DbName + ' to  ' + @PathAndFilename
  Print '----------------------------------------------------------'
  Print ''

  Set @sql = 
    '
    BACKUP DATABASE [<DbName>] TO DISK ="<nomSauvegarde>" WITH stats=1, INIT, format, COPY_ONLY, NAME = "SaveDbCopyOnly: <nomSauvegarde>"
    '
  
  Set @sql = Replace( @sql, '<DbName>', @DbName )
  Set @sql = Replace( @sql, '<nomSauvegarde>', @PathAndFilename )
  Set @sql = Replace( @sql, '"', '''' )
  Set @sql = yExecNLog.Unindent_TSQL(@sql)
  Print @sql
  Print ''
  Exec (@sql)
  Set @errorN = @@error

  -- Revenir à l'impersonification de la Stored Procedure
  REVERT

End -- Maint.SaveDbCopyOnly
GO

Exec f$.DropObj 'Maint.duplicateDb'
GO

Create proc Maint.duplicateDb 
  @sourceDb nvarchar(512)
, @TargetDb nvarchar(512)
, @PathAndFilename nvarchar(512) = NULL -- complete name including path otherwise use last backup location + @TargetDb + '.bak'
, @KeepBackupFile bit = 0 -- by default destroy intermediate backup file, otherwise specify 1 to keep it
With Execute as Self
as 
Begin
  Declare @sql nvarchar(max)
  Declare @AlterLogicalFiles nvarchar(max)
  Declare @cmd nvarchar(1000)
  Declare @FullBackupPath nvarchar(512)
  Declare @NoSeq int
  Declare @name sysname
  Declare @separateur int
  Declare @physical_name nvarchar(260)
  Declare @ClauseMove nvarchar(max)
  Declare @BackupErr int

  Set nocount on
  
  If @PathAndFilename is NULL 
  Begin
    Select @FullBackupPath = yUtl.GetPathFromName(lastFullBkpFile)
    From Maint.JobLastBkpLocations
    Where dbName = @sourceDb

    If @FullBackupPath IS NULL 
    Begin
      raiserror('No maintenance has been done yet on this database, complete @PathAndFilename parameter',11,1)
      return 
    End 
    Set @PathAndFilename = @FullBackupPath + @TargetDb + '.Bak'
  End
  
  Exec Maint.SaveDbCopyOnly @DbName=@sourceDb, @PathAndFilename=@PathAndFilename, @errorN = @BackupErr output
  Print ''

  -- Stop processing it any backup error
  If @BackupErr <> 0
    Return 

  Create Table #dbfiles( noseq int, name sysname, physical_name nvarchar(260), separateur int)
  -- 
  Set @sql =
  '
  Use <DbName>

  Insert Into #dbfiles (noseq, name, physical_name, separateur )
  Select
    ROW_NUMBER() OVER(ORDER BY name),
    name
  , physical_name
  , Charindex("\", Reverse(physical_name))
  FROM [<DbName>].sys.database_files
  '

  Set @sql = replace(@sql, '"', '''')
  Set @sql = replace(@sql, '<DbName>', @sourceDb)
  Set @sql = yExecNLog.Unindent_TSQL(@sql)

  Exec (@sql)

  Print '----------------------------------------------------------------------------------------------------'
  Print 'Database ' + @TargetDb + ' is created from ' + @PathAndFilename
  Print '----------------------------------------------------------------------------------------------------'
  Print ''

  Set @AlterLogicalFiles = ''
  
  -- Generate restore command
  Set @sql = 
  'RESTORE DATABASE [<DbNameDest>]
   FROM DISK="<nomSauvegarde>" 
   WITH 
     stats=1,REPLACE
   <ClauseMove>
  '

  Set @NoSeq = 1

  While 1=1
  Begin
    Select @name=name, @physical_name=physical_name, @separateur=separateur
    From #dbfiles
    Where noseq = @NoSeq

    If @@rowcount = 0 break
       
    Set @ClauseMove = ', MOVE "<logicalname>" TO "<physical_path><physical_name>"'

    Set @ClauseMove = Replace( @ClauseMove, '<logicalname>', @name )
    Set @ClauseMove = Replace( @ClauseMove, '<physical_path>', Left(@physical_name, len(@physical_name) - @separateur) )
    Set @ClauseMove = Replace( @ClauseMove, '<physical_name>'
                             , Replace( Right(@physical_name, @separateur), @sourceDb, @TargetDb ))

    Set @sql = Replace(@sql, '<ClauseMove>', @ClauseMove + nchar(13) + nchar(10) + '<ClauseMove>') 


    If Replace(@name, @sourceDb, @TargetDb) <> @name
    Begin
      Set @AlterLogicalFiles = @AlterLogicalFiles 
                             + ' ALTER DATABASE [<DbNameDest>] MODIFY FILE (NAME="<logicalname>", NEWNAME="<new_logicalname>")' 
                             + nchar(13) 
                             + nchar(10)
	  Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '<DbNameDest>', @TargetDb)
	  Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '<logicalname>', @name)
	  Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '<new_logicalname>', Replace(@name, @sourceDb, @TargetDb) )
	End

    Set @NoSeq = @NoSeq + 1

  End

  Drop Table #dbfiles

  Set @sql = Replace(@sql, '<ClauseMove>', '')
  Set @sql = replace (@sql, '"', '''')
  Set @sql = replace (@sql, '<DbNameDest>', @TargetDb)
  Set @sql = replace (@sql, '<nomSauvegarde>', @PathAndFilename)
  Set @sql = yExecNLog.Unindent_TSQL(@sql)
  
  Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '"', '''')
  Set @AlterLogicalFiles = yExecNLog.Unindent_TSQL(@AlterLogicalFiles)  

  -- Execute restore with original login permission
  EXECUTE AS LOGIN = ORIGINAL_LOGIN();
  Print @sql
  Exec (@sql)

  Print ''
  
  If Len(@AlterLogicalFiles) > 0
  Begin
    Print @AlterLogicalFiles
    Exec (@AlterLogicalFiles)
  End
  
  REVERT

  If @KeepBackupFile = 0
  Begin
    Print ''
    Print '----------------------------------------------------------'
    Print 'Deleting database backup file ' + @PathAndFilename
    Print '----------------------------------------------------------'
    Print ''
    Declare @err nvarchar(4000)
    Exec yUtl.Clr_DeleteFile @PathAndFilename, @Err output
    If @err is not NULL Print @err
  End

End -- Maint.duplicateDb
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.duplicateDbFromBackupHistory'
GO
Create proc Maint.duplicateDbFromBackupHistory 
  @SourceDb nvarchar(512)
, @TargetDb nvarchar(512)
, @DoLogBackup int = 1
, @RestoreToSimpleRecoveryModel int = 1
With Execute as Self
as 
Begin
  Declare @sql nvarchar(max)
  Declare @AlterLogicalFiles nvarchar(max)
  Declare @cmd nvarchar(1000)
  Declare @lastFullBkpFile nvarchar(512)
  Declare @lastLogBkpFile nvarchar(512)
  Declare @NoSeq int
  Declare @name sysname
  Declare @separateur int
  Declare @physical_name nvarchar(260)
  Declare @ClauseMove nvarchar(max)

  Declare @RestoreLog nvarchar(max)
  Declare @position smallint
  Declare @LogBkpFile nvarchar(512)
  Declare @MediaSetId int

  Set nocount on
  
  Select 
    @lastFullBkpFile = lastFullBkpFile
  , @lastLogBkpFile = lastLogBkpFile
  From Maint.JobLastBkpLocations
  Where dbName = @SourceDb

  If @SourceDb = @TargetDb
  Begin
    raiserror('@SourceDb and @TargetDb can''t be the same',11,1)
    return 
  End

  If IsNull(@lastLogBkpFile, '') = ''
  Begin
    raiserror('No log backups has been done yet on this database.  Use «DuplicateDb» stored procedure to Duplicate this database',11,1)
    return 
  End
  
  -- If sprecified do a last log backup for the database
  If @DoLogBackup = 1
  Begin
    Print '----------------------------------------------------------------------------------------------------'
    Print 'Doing a log backup on source database « ' + @SourceDb + '» to have the most up to date data'
    Print '----------------------------------------------------------------------------------------------------'
    Print ''
  
    Set @sql = yMaint.MakeBackupCmd( @SourceDb, 'L', @lastLogBkpFile, 0, Null)
    Exec(@sql)        
  End
    
  Create Table #dbfiles( noseq int, name sysname, physical_name nvarchar(260), separateur int)
  -- 
  Set @sql =
  '
  Use <DbName>

  Insert Into #dbfiles (noseq, name, physical_name, separateur )
  Select
    ROW_NUMBER() OVER(ORDER BY name),
    name
  , physical_name
  , Charindex("\", Reverse(physical_name))
  FROM [<DbName>].sys.database_files
  '

  Set @sql = replace(@sql, '"', '''')
  Set @sql = replace(@sql, '<DbName>', @sourceDb)
  Set @sql = yExecNLog.Unindent_TSQL(@sql)

  Exec (@sql)

  Print '----------------------------------------------------------------------------------------------------'
  Print 'Database ' + @TargetDb + ' is created from ' + @SourceDb + ' backup chain'
  Print '----------------------------------------------------------------------------------------------------'
  Print ''

  Set @AlterLogicalFiles = ''
  
  -- Generate restore command
  Set @sql = 
  'RESTORE DATABASE [<DbNameDest>]
   FROM DISK="<nomSauvegarde>" 
   WITH 
     stats=1,REPLACE,NORECOVERY
   <ClauseMove>
  <LogRestore>
  Restore Log [<DbNameDest>] With Recovery   
  '

  Set @NoSeq = 1

  While 1=1
  Begin
    Select @name=name, @physical_name=physical_name, @separateur=separateur
    From #dbfiles
    Where noseq = @NoSeq

    If @@rowcount = 0 break
       
    Set @ClauseMove = ', MOVE "<logicalname>" TO "<physical_path><physical_name>"'

    Set @ClauseMove = Replace( @ClauseMove, '<logicalname>', @name )
    Set @ClauseMove = Replace( @ClauseMove, '<physical_path>'
                             , Left(@physical_name, len(@physical_name) - @separateur) )
    Set @ClauseMove = Replace( @ClauseMove, '<physical_name>'
                             , Replace( Right(@physical_name, @separateur), @sourceDb, @TargetDb ))

    Set @sql = Replace(@sql, '<ClauseMove>', @ClauseMove + nchar(13) + nchar(10) + '<ClauseMove>') 


    If Replace(@name, @sourceDb, @TargetDb) <> @name
    Begin
      Set @AlterLogicalFiles = @AlterLogicalFiles 
                             + ' ALTER DATABASE [<DbNameDest>] MODIFY FILE (NAME="<logicalname>", NEWNAME="<new_logicalname>")' 
                             + nchar(13) 
                             + nchar(10)
	     Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '<DbNameDest>', @TargetDb)
	     Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '<logicalname>', @name)
	     Set @AlterLogicalFiles = replace ( @AlterLogicalFiles, '<new_logicalname>'
	                                      , Replace(@name, @sourceDb, @TargetDb) )
	    End

    Set @NoSeq = @NoSeq + 1

  End
 
  -- Find all log backups associated with the full backup    
  Set @MediaSetId = 0
  While 1=1
  Begin
  
    Select Top 1 @MediaSetId= bm.media_set_id,  @LogBkpFile = bm.physical_device_name
    From
      (
      Select bs.database_name, bs.first_lsn
      From 
        YourSQLDba.Maint.JobLastBkpLocations lb
        join
        msdb.dbo.backupset bs
        on   bs.database_name = lb.dbName collate database_default
         And RIGHT( bs.name, Len(lb.lastFullBkpFile)) = lb.lastFullBkpFile collate database_default
      Where lb.lastFullBkpFile = @lastFullBkpFile
        And (bs.name like 'YourSqlDba%' or bs.name like 'SaveDbOnNewFileSet%')
        And bs.type = 'D'
      ) X
      
      Join
      msdb.dbo.backupset bs
      On   bs.database_name = X.database_name
       And bs.database_backup_lsn = X.first_lsn
       
      Join
      msdb.dbo.backupmediafamily bm
      On  bm.media_set_id = bs.media_set_id
      
    Where bs.type = 'L' 
      And bm.media_set_id > @MediaSetId 
      
    If @@ROWCOUNT = 0
      Break
      
      
    -- Generate instruction to restore all logs backups of this database
    -- if any error they are displayed from the called proc with a raiserror
    Declare @rc int
    Exec @rc=yMaint.CollectBackupHeaderInfoFromBackupFile @LogBkpFile 
    If @rc <> 0
      Return

    -- Restore all log backups
    Set @position = 0
    while 1=1
    Begin
    
      Select Top 1 @position = Position
      From Maint.TemporaryBackupHeaderInfo 
      Where spid = @@spid
        And BackupType = 2
        And Position > @position
      Order by Position
      
      If @@rowcount= 0
        break
        
      Set @RestoreLog = 'Restore Log [<DbNameDest>] From Disk="<LogBackupFile>" With FILE=<Position>, NoRecovery'  
      
      Set @RestoreLog = Replace(@RestoreLog, '<DbNameDest>', @TargetDb)
      Set @RestoreLog = Replace(@RestoreLog, '<LogBackupFile>', @LogBkpFile)
      Set @RestoreLog = Replace(@RestoreLog, '<Position>', Convert(nvarchar(255), @position))
      
      Set @Sql = replace(@Sql, '<LogRestore>', @RestoreLog +  Char(13) + Char(10) + '<LogRestore>' )  
        
    End
  
  End  
      
  Drop Table #dbfiles

  Set @sql = replace(@sql, '<LogRestore>', '')
  Set @sql = Replace(@sql, '<ClauseMove>', '')
  Set @sql = replace (@sql, '"', '''')
  Set @sql = replace (@sql, '<DbNameDest>', @TargetDb)
  Set @sql = replace (@sql, '<nomSauvegarde>', @lastFullBkpFile)
  Set @sql = yExecNLog.Unindent_TSQL(@sql)
    
  Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '"', '''')
  Set @AlterLogicalFiles = yExecNLog.Unindent_TSQL(@AlterLogicalFiles)
    
  -- Execute restore with original login permission
  EXECUTE AS LOGIN = ORIGINAL_LOGIN();

  Begin Try  
    --Print @sql    
    Exec (@sql)
  End Try
  Begin Catch
    Declare @Info nvarchar(max)
    Set @Info =
    'Error_no: '+ Convert(varchar(10), ERROR_NUMBER())+','+
    'Severity: '+ Convert(varchar(10), ERROR_SEVERITY())+','+
    'Status: '+  Convert(varchar(10), ERROR_STATE())+','+
    'LineNo: '+  Convert(varchar(10), ERROR_LINE())+','+
    'Msg: '+ ERROR_MESSAGE()  
  
    raiserror(@Info,11,1)
    return 
  
  End Catch

  REVERT

  Print ''
  
  If Len(@AlterLogicalFiles) > 0
  Begin  
    --Print @AlterLogicalFiles
    Exec (@AlterLogicalFiles)
  End
  
  -- Ensure database is in SIMPLE recovery model if parameter @RestoreToSimpleRecoveryModel is set to 1
  If @RestoreToSimpleRecoveryModel = 1
  Begin
    Set @sql = 'ALTER DATABASE [<DbNameDest>] SET RECOVERY SIMPLE'
    Set @sql = REPLACE(@sql, '<DbNameDest>', @TargetDb)
    
    Exec (@sql)
  End
  
End -- Maint.duplicateDbFromBackupHistory

GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.RestoreDb'
GO

Create proc Maint.RestoreDb 
  @TargetDb nvarchar(512)        -- database name to restore
, @PathAndFilename nvarchar(512) -- complete file and path name must be given 
, @ReplaceExistingDb int = 0  -- set to 1 to overwrite existing database «REPLACE option»
With Execute as Self
as 
Begin

  If exists (select * from master.sys.databases where name = @TargetDb)
  and @ReplaceExistingDb = 0 
  begin
    Print 'Database '
    + @TargetDb
    Print 'already exists and you did not allow to replace it with parameter @ReplaceExistingDb'
    Print 'Restore action is cancelled'
    Return
  end

  Declare @pathData nvarchar(512)
  Declare @pathLog nvarchar(512)
  Declare @FileType char(1)
  Declare @sql nvarchar(max)
  Declare @FileId int
  Declare @NoSeq int
  Declare @LogicalName sysname
  Declare @PhysicalName sysname
  Declare @DbName sysname
  Declare @NewPhysicalName sysname
  Declare @ClauseMove nvarchar(max)
  Declare @AlterLogicalFiles nvarchar(max)
  declare @rc int
  
  Set nocount on

  -- get default data and log location
		Exec master.dbo.xp_instance_regread 
		  N'HKEY_LOCAL_MACHINE'
		, N'Software\Microsoft\MSSQLServer\MSSQLServer'
		, N'DefaultData'
		, @pathData OUTPUT
		Exec master.dbo.xp_instance_regread 
		  N'HKEY_LOCAL_MACHINE'
		, N'Software\Microsoft\MSSQLServer\MSSQLServer'
		, N'DefaultLog'
		, @pathLog OUTPUT

  -- if default data and log location is not specified in server properties, Use master database file location
  If @pathData Is Null
    Select Top 1 @pathData = Left( physical_name, Len(physical_name) - Charindex('\', Reverse(physical_name))) 
    FROM master.sys.database_files 
    Where type = 0

  If @pathLog Is Null
    Select Top 1 @pathLog = Left( physical_name, Len(physical_name) - Charindex('\', Reverse(physical_name))) 
    FROM master.sys.database_files 
    Where type = 1

  -- recover database name from datase backup file
  -- if there is any errors thay are displayed from CollectBackupHeaderInfoFromBackupFile with a raiserrpr
  Exec @rc=yMaint.CollectBackupHeaderInfoFromBackupFile @PathAndFilename
  If @rc <> 0
    Return

  Select @DbName = DatabaseName
  From Maint.TemporaryBackupHeaderInfo 
  Where spid = @@spid

  Exec @rc=yMaint.CollectBackupFileListFromBackupFile @PathAndFilename
  If @rc <> 0
    Return

  Print '----------------------------------------------------------------------------------------------------'
  Print 'Database ' + @TargetDb + ' is created from ' + @PathAndFilename
  Print '----------------------------------------------------------------------------------------------------'
  Print ''

  Set @AlterLogicalFiles = ''

  -- Generate restore command
  Set @sql = 
  'RESTORE DATABASE [<DbNameDest>]
   FROM DISK="<nomSauvegarde>" 
   WITH 
   <ClauseMove><Replace>
  '

  Set @FileId = -1
  Set @NoSeq = 0

  While 1=1
  Begin
    Select Top 1 
      @FileType = Type
    , @FileId = FileId
    , @LogicalName=LogicalName
    , @PhysicalName=RIGHT(PhysicalName, Charindex('\', Reverse(PhysicalName)) - 1) 
    From Maint.TemporaryBackupFileListInfo 
    Where Spid = @@spid And FileId > @FileId
    Order by spid, FileId

    If @@rowcount = 0 break
    
    Set @ClauseMove = 'MOVE "<logicalname>" TO "<physical_path>\<physical_name>"'

    Set @ClauseMove = Replace( @ClauseMove, '<logicalname>', @LogicalName )

    If Replace(@LogicalName, @DbName, @TargetDb) <> @LogicalName
    Begin
      Set @AlterLogicalFiles = @AlterLogicalFiles 
                             + ' ALTER DATABASE [<DbNameDest>] MODIFY FILE (NAME="<logicalname>", NEWNAME="<new_logicalname>")' 
                             + nchar(13) 
                             + nchar(10)
      Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '<DbNameDest>', @TargetDb)
      Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '<logicalname>', @LogicalName)
      Set @AlterLogicalFiles = replace ( @AlterLogicalFiles
                                       , '<new_logicalname>'
                                       , Replace(@LogicalName, @DbName, @TargetDb) )
    End

    -- Try only a replace of the old database name by the new database name
    -- in filename on disk.  If it doesn't work we will have no choice to generate distinct names

    If Charindex(@DbName, @PhysicalName) > 0
    Begin
      Set @ClauseMove = Replace( @ClauseMove
                               , '<physical_path>'
                               , Case When @FileType = 'L' Then @pathLog Else @pathData End )
      Set @ClauseMove = Replace( @ClauseMove
                               , '<physical_name>'
                               , Replace(@PhysicalName, @DbName, @TargetDb) )
    End
    Else
    Begin

      -- Log file name will be renamed by database name followed by «_Log.ldf»
      If @FileType = 'L' 
      Begin
        Set @ClauseMove = Replace( @ClauseMove, '<physical_path>', @pathLog )
        Set @ClauseMove = Replace( @ClauseMove, '<physical_name>', @TargetDb + '_Log.ldf' )
      End

      -- Data file name are named from database name
      -- A sequential number is added for databases that have many file name
      If @FileType = 'D' 
      Begin
        Set @ClauseMove = Replace( @ClauseMove, '<physical_path>', @pathData )

        If @NoSeq = 0
          Set @ClauseMove = Replace( @ClauseMove, '<physical_name>', @TargetDb + '.mdf' )
        Else
          Set @ClauseMove = Replace( @ClauseMove
                                   , '<physical_name>'
                                   , @TargetDb + convert(nvarchar, @NoSeq) + '.ndf')

        Set @NoSeq = @NoSeq + 1
      End

      -- Catalog file for full text search are named from database name 
      -- with extension «.FtCatalog» plus a sequential number
      If @FileType = 'F' 
      Begin
        Set @ClauseMove = Replace( @ClauseMove, '<physical_path>', @pathData )

        Set @ClauseMove = Replace( @ClauseMove
                                 , '<physical_name>'
                                 , @TargetDb + '.FTCatalog' + convert(nvarchar, @NoSeq) )

        Set @NoSeq = @NoSeq + 1
      End

    End

    Set @sql = Replace( @sql
                      , '<ClauseMove>'
                      , @ClauseMove + nchar(13) + nchar(10) + ',<ClauseMove>') 

  End

  Set @sql = Replace(@sql, ',<ClauseMove>', '')
  Set @sql = replace (@sql, '"', '''')
  Set @sql = replace (@sql, '<DbNameDest>', @TargetDb)
  Set @sql = replace (@sql, '<nomSauvegarde>', @PathAndFilename)
  Set @sql = replace ( @sql
                     , '<Replace>'
                     , Case When @ReplaceExistingDb = 1 Then ', REPLACE' Else '' End )
  Set @sql = yExecNLog.Unindent_TSQL(@sql)

  Set @AlterLogicalFiles = replace (@AlterLogicalFiles, '"', '''')
  Set @AlterLogicalFiles = yExecNLog.Unindent_TSQL(@AlterLogicalFiles)
  
  -- Execute a Restore with original login's permissions
  EXECUTE AS LOGIN = ORIGINAL_LOGIN();
  Print @sql
  Exec (@sql)

  Print ''

  If Len(@AlterLogicalFiles) > 0
  Begin
    Print @AlterLogicalFiles
    Exec (@AlterLogicalFiles)
  End

  REVERT

End -- Maint.RestoreDb
GO

ALTER DATABASE YourSQLDba Set Trustworthy on
GO
GRANT connect to guest
GO
grant execute on Maint.SaveDbOnNewFileSet to guest
GO
grant execute on Maint.SaveDbCopyOnly to guest
GO
grant execute on Maint.DuplicateDb to guest
GO
grant execute on Maint.DuplicateDbFromBackupHistory to guest
GO
grant execute on Maint.RestoreDb to guest
GO
-- some tests
--Exec Maint.SaveDbOnNewFileSet 
--  @DbName = 'RegardMaurice'
--, @FullBackupPath = null
--, @LogBackupPath = null
GO
-- ------------------------------------------------------------------------------
-- Procedure to visualize last statement running or ran
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUtl.TextSplitInRows'
GO
create FUNCTION yUtl.TextSplitInRows 
(
  @sql nvarchar(max)
)
RETURNS @TxtSql TABLE (i int identity, txt nvarchar(max))
AS 
Begin
  declare @i int, @d Datetime
  If @i > 0
    Insert into @txtSql (txt) 
    values ('-- Seq:'+ltrim(str(@i))+
            ' Time:'+convert(nvarchar(20), @d, 120) +  ' ' + replicate('-', 10) )

  If @sql is null Or @sql = ''
  Begin
    Insert into @txtSql (txt) values ('')
    return
  End

  declare @Start int, @End Int, @line nvarchar(max), @EOLChars int
  Set @Start = 1 Set @End=0

  While(@End < len(@sql))
  Begin
    ;With NearestEndOfLines as
    (
    Select charindex(nchar(13)+nchar(10), @sql, @Start) as EOLPos, 2 as EOLChars 
    union All
    Select charindex(nchar(13), @sql, @Start) as EOLPos, 1 as EOLChars           
    union All
    Select charindex(nchar(10), @sql, @Start) as EOLPos, 1 as EOLChars
    )
    Select top 1 
      @End = Case When EOLPos > 0 Then EOLPos Else LEN(@Sql) End -- End of String @Sql
    , @EOLChars = Case When EOLPos > 0 Then EOLChars Else 1 End -- EOL length
    From NearestEndOfLines
    Order by EOLPos, EolChars Desc  -- get nearest EndOfLines
       
    Set @line = Substring(@sql, @Start, @End-@Start+@EOLChars)
    Set @Start = @End+@EOLChars
    Insert into @txtSql (txt) 
    values (replace (replace (@line, nchar(10), ''), nchar(13), ''))
  End
  RETURN
End -- yUtl.TextSplitInRows
GO
-- ---------------------------------------------------------------------------------------
-- Procedure to show maintenance log history
-- ---------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.ShowHistory'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc Maint.ShowHistory 
  @JobNo Int = NULL
, @FilterErr Int = 0
, @DispLimit Int = NULL
, @Diag int = 0
as
Begin
  set nocount on 
  Declare @nbLig Int
  Declare @NoTravSel Int

  If @JobNo is NULL
    Select top 1 @noTravSel = JobNo 
    From  Maint.JobHistory T
    order by JobNo desc
  Else
    Set @noTravSel = @JobNo

  If @DispLimit > 40 Or @DispLimit is NULL
    Set @nbLig = 40
  Else
    Set @nbLig  = @DispLimit

  Select top (@nbLig)  JobNo into #JobNo
  From  Maint.JobHistory T
  Where (@JobNo is NULL Or JobNo <= @JobNo)
    And Exists 
        (
        Select * 
        From  Maint.JobHistoryDetails H
        Where H.JobNo = T.JobNo
          And (@FilterErr = 1 Or H.ForDiagOnly <= @diag) -- si erreurs demandées aff. tout, sinon limiter au diag spécifié
          And (  @FilterErr <> 1 
              Or (   @FilterErr = 1  
                 And yExecNLog.ErrorPresentInAction(action) = 1
                 )
              )      
        )
  order by JobNo desc

  While (1=1)
  Begin
    Select top 1 @JobNo = JobNo
    From #JobNo
    Order by JobNo Desc
    
    If @@rowcount = 0 break
    Delete from #JobNo where JobNo = @JobNo 

    Select 
        convert(char(1),Case when JobNo = @noTravSel Then N'=' Else N' ' End) as I
      , JobNo, JobName, DoInteg, DoUpdStats, DoReorg, DoFullBkp, DoDiffBkp, DoLogBkp 
      , convert(varchar(20), JobStart, 120) as JobStart
      , convert(varchar(20), JobEnd, 120) as JobEnd
      , IncDb as [IncDb ……………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………]
      , ExcDb as [ExcDb ……………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………]
    From  Maint.JobHistory T
    Where (JobNo = @JobNo)

    Declare @sql nvarchar(max)
    Declare @ActionTitle nvarchar(150)
    Set @ActionTitle = 'Action'+replicate(nchar(0151),122) -- force a wide column display by using a wide title max 128
    Set @sql = 
    '
    Select 
      convert(char(1),Case when JobNo = @noTravSel Then N"=" Else N" " End) as I
    , H.JobNo
    , h.seq
    , convert(varchar(20), h.cmdStartTime, 120) as cmdStartTime, secs
    , h.Action as [<ActionTitle>]
    from 
      Maint.JobHistoryDetails H
    Where 
          JobNo = @JobNo 
      And (@FilterErr = 1 Or H.ForDiagOnly <= @diag) -- si erreurs demandées aff. tout, sinon limiter au diag spécifié
      And (  @FilterErr <> 1 
          Or (    @FilterErr = 1 
              And yExecNLog.ErrorPresentInAction(action) = 1
             )
          )
    Order by H.JobNo desc, h.seq Asc
    '
    Set @sql = REPLACE (@sql, '<actionTitle>', @ActionTitle)
    Set @sql = REPLACE (@sql, '"', '''')
    print @sql
    Exec sp_executeSql @sql, N'@JobNo Int, @diag Int, @noTravSel Int, @FilterErr int ', @jobNo, @Diag, @NoTravSel, @FilterErr 
  End -- while 

End -- Maint.ShowHistory 
GO
Exec f$.DropObj 'Maint.ShowHistoryErrors'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc Maint.ShowHistoryErrors
  @JobNo Int = NULL
, @displimit Int = 1
as
Begin
  Exec Maint.ShowHistory @JobNo = @JobNo, @FilterErr = 1, @dispLimit = @displimit
End
Go
---------------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Install.AddOrReplaceMaintenance'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc Install.AddOrReplaceMaintenance 
  @JobNameSuffix nvarchar(512) = ''
, @FullBackupPath nvarchar(512) 
, @LogBackupPath nvarchar(512) 
, @ConsecutiveDaysOfFailedBackupsToPutDbOffline Int
, @FullMaintenanceScript Nvarchar(max) = NULL Output 
, @LogBackupScript Nvarchar(max) = NULL Output 
As
--Declare @FullBackupPath nvarchar(512)
--Set @FullBackupPath = 'C:\SQL2005Backups\'
--

Begin
  ---------------------------------------------------------------------------------------
  -- Setup of 2 maintenance tasks
  ---------------------------------------------------------------------------------------
  Declare @nomJob Sysname

  If right(@FullBackupPath, 1)<>'\'
    Set @FullBackupPath = @FullBackupPath + '\'

  If right(@LogBackupPath, 1)<>'\'
    Set @LogBackupPath = @LogBackupPath + '\'

  Declare @JobLogFile sysname
  Set @JobLogFile = @FullBackupPath + 'MaintenanceReport.txt'

  Declare @svrName nvarchar(30)
  set @svrName = convert(nvarchar(30), serverproperty('servername'))
  Select @svrname
  Declare @sql nvarchar(max)

  DECLARE @jobId uniqueidentifier
  set @jobId = NULL

  Set @nomJob = N'YourSQLDba_FullBackups_And_Maintenance'+ISNULL(@JobNameSuffix, '')

  Declare @operator sysname
  Select @jobId = job_Id, @operator = OP.name
  from 
    msdb.dbo.sysjobs J
    left join
    msdb.dbo.sysoperators OP
    On Op.Id = notify_email_operator_id
  where J.name = @nomJob
  
  If @@rowcount = 0
  Begin
    if @operator is NULL Set @operator = 'YourSQLDba_Operator'
  
    Print 'Adding job maintenance task '+@nomJob
    EXEC  msdb.dbo.sp_add_job 
      @job_name = @nomJob, 
		    @enabled = 1, 
		    @notify_level_eventlog = 0, 
		    @notify_level_email = 2, 
		    @notify_email_operator_name = @operator,
		    @notify_level_netsEnd = 2, 
		    @notify_level_page = 2, 
		    @delete_level = 0, 
		    @description = N'Maintenance: Integrity tests, update statistics, index reorg, Full backups', 
		    @category_name = N'Database Maintenance', 
		    @owner_login_name = N'YourSQLDba', 
      @job_id = @jobId OUTPUT

    Print 'Maintenance server parameter setup '
    exec msdb.dbo.sp_add_jobserver @job_id = @jobId,  @server_name = @svrName
  End    
  Else     
  Begin
    if @operator is NULL Set @operator = 'YourSQLDba_Operator'
  
    Print 'Updating job maintenance task '+@nomJob
    EXEC  msdb.dbo.sp_update_job 
      @job_name = @nomJob, 
		    @enabled = 1, 
		    @notify_level_eventlog = 0, 
		    @notify_level_email = 2, 
		    @notify_email_operator_name = @operator,
		    @notify_level_netsEnd = 2, 
		    @notify_level_page = 2, 
		    @delete_level = 0, 
		    @description = N'Maintenance: Integrity tests, update statistics, index reorg, Full backups', 
		    @category_name = N'Database Maintenance', 
		    @owner_login_name = N'YourSQLDba'
  End

  set @sql =
  N'
  exec Maint.YourSqlDba_DoMaint
    @oper = "<operateur>"
  , @MaintJobName = "YourSQLDba: DoInteg,DoUpdateStats,DoReorg,Full backups"
  , @DoInteg = 1
  , @DoUpdStats = 1
  , @DoReorg = 1
  , @DoBackup = "F"
  , @FullBackupPath = "<destin>" 
  , @LogBackupPath = "<destinLog>"  
  -- Flush database backups older than the number of days
  , @FullBkpRetDays = 0 
  -- Flush log backups older than the number of days
  , @LogBkpRetDays = 8 
  -- Spread Update Stats over 7 days 
  , @SpreadUpdStatRun = 7 
  -- Spread Check DB without "PHYSICAL_ONLY" over 7 days
  , @SpreadCheckDb = 7
  -- Maximum number of consecutive days of failed full backups allowed
  -- for a database before putting that database (Offline). 
  , @ConsecutiveDaysOfFailedBackupsToPutDbOffline = <ConsecutiveDaysOfFailedBackupsToPutDbOffline> 
  -- Each database inclusion filter must be on its own line between the following quote pair
  , @IncDb = 
  " 
  " 
  -- Each database exclusion filter must be on its own line between the following quote pair
  , @ExcDb = 
  "
  " 
  -- Each database exclusion filter must be on its own line between the following quote pair
  , @ExcDbFromPolicy_CheckFullRecoveryModel = 
  "
  " 
  '
  Set @sql = replace (@sql, '"', '''') 
  Set @sql = replace (@sql, '<destin>', @FullBackupPath) 
  Set @sql = replace (@sql, '<destinLog>', @LogBackupPath) 
  Set @sql = replace (@sql, '<operateur>', @operator)
  Set @sql = replace ( @sql
                     , '<ConsecutiveDaysOfFailedBackupsToPutDbOffline>'
                     , convert(nvarchar(10),@ConsecutiveDaysOfFailedBackupsToPutDbOffline))
 
  Set @sql = yExecNLog.Unindent_TSQL(@sql)

  Set @FullMaintenanceScript = @Sql

  Declare @step_name sysname
  Declare @on_success_action int
  Declare @on_success_step_id int  
  Declare @on_fail_action int
  Declare @on_fail_step_id int  
  Declare @step_id Int
  Declare @schedule_id int
  Set @step_name = N'Exec YourSQLDba: Maintenance and Full Backups'
  
  If Not Exists(select * 
                from msdb.dbo.sysjobsteps 
                where job_Id = @jobId 
                  And step_name = @step_name)
  Begin
    Print 'Step Add '+@step_name
    EXEC msdb.dbo.sp_add_jobstep 
      @job_name = @nomJob,
      @step_name = @step_name , 
		    @step_id = 1, 
		    @cmdexec_success_code = 0, 
		    @on_success_action = 1, 
		    @on_fail_action = 2, 
		    @retry_attempts = 0, 
		    @retry_interval = 0, 
		    @os_run_priority = 0, @subsystem = N'TSQL', 
		    @command = @sql, 
		    @database_name = N'YourSQLDba', 
		    @output_file_name = @JobLogFile , 
		    @flags = 0 -- overwrite log file
  End
		Else    
  Begin
    Print 'Step Update '+@step_name
    select 
      @step_id = step_id 
    , @on_success_action = on_success_action  
    , @on_fail_action = on_fail_action
    , @on_success_step_id = on_success_step_id
    , @on_fail_Step_id = on_fail_Step_id
    from msdb.dbo.sysjobsteps where job_Id = @jobId And step_name = @step_name
    EXEC msdb.dbo.sp_update_jobstep 
      @job_name = @nomJob,
      @step_name = @step_name , 
		    @step_id = @step_id, 
		    @cmdexec_success_code = 0, 
		    @on_success_action = @on_success_action, 
      @on_success_step_id = @on_success_step_id,
		    @on_fail_action = @on_fail_action, 
      @on_fail_Step_id = @on_fail_Step_id,
		    @retry_attempts = 0, 
		    @retry_interval = 0, 
		    @os_run_priority = 0, @subsystem = N'TSQL', 
		    @command = @sql, 
		    @database_name = N'YourSQLDba', 
		    @output_file_name = @JobLogFile , 
		    @flags = 0 -- overwrite log file
  End

  Declare @schedule_name sysname
  Set @schedule_name = N'Schedule for Maintenance and full backups'
  Set @schedule_id = NULL

  Select @schedule_id = s.schedule_id 
  From 
    msdb.dbo.sysschedules s
    Join
    msdb.dbo.sysjobschedules js
    On   s.schedule_id =  js.schedule_id
     And js.job_id = @jobId 
  Where name = @schedule_name

  If @schedule_id Is Null
  Begin
    Print 'Adding Schedule '+ @schedule_name 
    Exec msdb.dbo.sp_add_schedule 
        @schedule_name = @schedule_name 
      , @enabled = 1
      , @freq_type = 8
      , @freq_interval = 127
      , @freq_subday_type = 1
      , @freq_subday_interval = 0 
      , @freq_relative_interval = 0 
      , @freq_recurrence_factor = 1
      , @active_start_date = NULL
      , @active_end_date =  99991231
      , @active_start_time = 000000
      , @active_end_time = 235959
      , @owner_login_name = 'YourSQLDba'
      , @schedule_id = @schedule_id OUTPUT

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = @nomJob
      , @schedule_id = @schedule_id
  End
  Else 
  Begin  
    Print 'Schedule update '+ @schedule_name 
    Exec msdb.dbo.sp_update_schedule 
        @schedule_id = @schedule_id 
      , @enabled = 1
      , @freq_type = 8
      , @freq_interval = 127
      , @freq_subday_type = 1
      , @freq_subday_interval = 0 
      , @freq_relative_interval = 0 
      , @freq_recurrence_factor = 1
      , @active_start_date = NULL
      , @active_end_date =  99991231
      , @active_start_time = 000000
      , @active_end_time = 235959
      , @owner_login_name = 'YourSQLDba'
  End  
  -- ---------------------------------------------------------------------------------------------------
  set @jobId = NULL
  Set @nomJob = N'YourSQLDba_LogBackups'+ISNULL(@JobNameSuffix, '')

  Select @jobId = job_Id, @operator = OP.name
  from 
    msdb.dbo.sysjobs J
    left join
    msdb.dbo.sysoperators OP
    On Op.Id = notify_email_operator_id
  where J.name = @nomJob
  
  If @@rowcount = 0
  Begin
    if @operator is NULL Set @operator = 'YourSQLDba_Operator'
    Print 'Adding job maintenance task '+@nomJob
    EXEC  msdb.dbo.sp_add_job 
      @job_name = @nomJob, 
		    @enabled = 1, 
		    @notify_level_eventlog = 0, 
		    @notify_level_email = 2, 
		    @notify_email_operator_name = @operator,
		    @notify_level_netsEnd = 2, 
		    @notify_level_page = 2, 
		    @delete_level = 0, 
		    @description = N'Log backups', 
		    @category_name = N'Database Maintenance', 
		    @owner_login_name = N'YourSQLDba', 
      @job_id = @jobId OUTPUT

    Print 'Maintenance task''s server parameter setup '+@nomJob
    exec msdb.dbo.sp_add_jobserver @job_id = @jobId,  @server_name = @svrName
  End
  Else
  Begin
    if @operator is NULL Set @operator = 'YourSQLDba_Operator'
    Print 'Updating job maintenance task '+@nomJob
    EXEC  msdb.dbo.sp_update_job 
      @job_name = @nomJob, 
		    @enabled = 1, 
		    @notify_level_eventlog = 0, 
		    @notify_level_email = 2, 
		    @notify_email_operator_name = @operator,
		    @notify_level_netsEnd = 2, 
		    @notify_level_page = 2, 
		    @delete_level = 0, 
		    @description = N'Log backups', 
		    @category_name = N'Database Maintenance', 
		    @owner_login_name = N'YourSQLDba'
  End

  set @sql =
  N'
  exec Maint.YourSqlDba_DoMaint
    @oper = "<operateur>"
  , @MaintJobName = ''Log backups''
  , @DoBackup = ''L''
  , @FullBackupPath = "<destin>" 
  , @LogBackupPath = "<destinLog>" 
  -- Specify to user that full database backups are mandatory before log backups
  , @NotifyMandatoryFullDbBkpBeforeLogBkp = 1 
  , @BkpLogsOnSameFile = 1
  -- Each database inclusion filter must be on its own line between the following quote pair
  , @IncDb = 
  " 
  " 
  -- Each database exclusion filter must be on its own line between the following quote pair
  , @ExcDb = 
  "
  " 
  '
  Set @sql = replace (@sql, '"', '''') 
  Set @sql = replace (@sql, '<destin>', @FullBackupPath) 
  Set @sql = replace (@sql, '<destinLog>', @LogBackupPath) 
  Set @sql = replace (@sql, '<operateur>', @operator)
  Set @sql = yExecNLog.Unindent_TSQL(@sql)

  Set @LogBackupScript = @Sql

  Set @step_name = N'Exec YourSQLDba_DoMaint Log Backups'

  If Not Exists(select * 
                from msdb.dbo.sysjobsteps 
                where job_Id = @jobId 
                  And step_name = @step_name)
  Begin
    Print 'Step Add '+@step_name
    EXEC msdb.dbo.sp_add_jobstep 
      @job_name = @nomJob,
      @step_name = @step_Name, 
		    @step_id = 1, 
		    @cmdexec_success_code = 0, 
		    @on_success_action = 1, 
		    @on_fail_action = 2, 
		    @retry_attempts = 0, 
		    @retry_interval = 0, 
		    @os_run_priority = 0, @subsystem = N'TSQL', 
		    @command = @sql, 
		    @database_name = N'YourSQLDba', 
		    @output_file_name = @JobLogFile , 
		    @flags = 2 -- append to the log file
  End
  Else 
  Begin
    Print 'Step Update '+@step_name
    select 
      @step_id = step_id 
    , @on_success_action = on_success_action  
    , @on_fail_action = on_fail_action
    , @on_success_step_id = on_success_step_id
    , @on_fail_Step_id = on_fail_Step_id
    from msdb.dbo.sysjobsteps where job_Id = @jobId And step_name = @step_name
    EXEC msdb.dbo.sp_update_jobstep 
      @job_name = @nomJob,
      @step_name = @step_name , 
		    @step_id = @step_id, 
		    @cmdexec_success_code = 0, 
		    @on_success_action = @on_success_action, 
      @on_success_step_id = @on_success_step_id,
		    @on_fail_action = @on_fail_action, 
      @on_fail_Step_id = @on_fail_Step_id,
		    @retry_attempts = 0, 
		    @retry_interval = 0, 
		    @os_run_priority = 0, @subsystem = N'TSQL', 
		    @command = @sql, 
		    @database_name = N'YourSQLDba', 
		    @output_file_name = @JobLogFile , 
		    @flags = 2 -- append output to previous job step
  End

  Set @schedule_name = N'Schedule for Log backups'
  Set @schedule_id = NULL

  Select @schedule_id = s.schedule_id 
  From 
    msdb.dbo.sysschedules s
    Join
    msdb.dbo.sysjobschedules js
    On   s.schedule_id =  js.schedule_id
     And js.job_id = @jobId 
  Where name = @schedule_name

  If @schedule_id Is Null
  Begin
    Print 'Adding Schedule '+ @schedule_name 
    Exec msdb.dbo.sp_add_schedule 
        @schedule_name = @schedule_name 
      , @enabled = 1
      , @freq_type = 8
      , @freq_interval = 127
      , @freq_subday_type = 4
      , @freq_subday_interval = 15
      , @freq_relative_interval = 0 
      , @freq_recurrence_factor = 1
      , @active_start_date = NULL
      , @active_end_date =  99991231
      , @active_start_time = 001000
      , @active_end_time = 235959
      , @owner_login_name = 'YourSQLDba'
      , @schedule_id = @schedule_id OUTPUT

    EXEC msdb.dbo.sp_attach_schedule
        @job_name = @nomJob
      , @schedule_id = @schedule_id
  End
  Else 
  Begin    
    Print 'Schedule update '+ @schedule_name 
    Exec msdb.dbo.sp_Update_schedule 
        @schedule_id = @schedule_id 
      , @enabled = 1
      , @freq_type = 8
      , @freq_interval = 127
      , @freq_subday_type = 4
      , @freq_subday_interval = 15
      , @freq_relative_interval = 0 
      , @freq_recurrence_factor = 1
      , @active_start_date = NULL
      , @active_end_date =  99991231
      , @active_start_time = 001000
      , @active_end_time = 235959
      , @owner_login_name = 'YourSQLDba'
  End
End
---------------------------------------------------------------------------------------------
-- To be done once when YourSqlDba script is run for the first time on a server 
---------------------------------------------------------------------------------------------
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Install.InitialSetupOfYourSqlDba'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
create proc Install.InitialSetupOfYourSqlDba 
  @FullBackupPath nvarchar(512) = NULL
, @LogBackupPath nvarchar(512) = NULL
, @email nvarchar(512) 
, @sourceEmail nvarchar(512) = ''
, @SmtpMailServer nvarchar(128)
, @SmtpMailPort int = 25
, @SmtpMailEnableSSL bit = 0
, @EmailServerAccount nvarchar(512) = NULL
, @EmailServerPassword nvarchar(512) = NULL
, @ConsecutiveDaysOfFailedBackupsToPutDbOffline Int
, @FullMaintenanceScript nvarchar(max) = '' Output 
, @LogBackupScript nvarchar(max) = '' Output 
As
--Declare @FullBackupPath nvarchar(512)
--Set @FullBackupPath = 'C:\SQL2005Backups\'
--

Begin
  Set nocount on

  If @ConsecutiveDaysOfFailedBackupsToPutDbOffline < 1
  Begin
    print 'YourSQLDba initial configuration failed'
    print ''
    print 'You must read the description of the @ConsecutiveDaysOfFailedBackupsToPutDbOffline'
    print 'parameter for the InitialSetupOfYourSqlDba procedure in the "YourSQLDba guide".'
    Return
  End

  Declare @oper sysname Set @oper = 'YourSQLDba_Operator'
  -------------------------------------------------------------
  --  database mail setup for YourSQLDba
  -------------------------------------------------------------
  If not Exists
     (
     Select *
     From  sys.configurations
     Where name = 'show advanced options' 
       And value_in_use = 1
     )
  Begin
    EXEC sp_configure 'show advanced options', 1
    Reconfigure
  End  

  -- To enable the feature.
  If not Exists
     (
 		  Select *
		   From  sys.configurations
		   Where name = 'Database Mail XPs' 
		     And value_in_use = 1
		   )
  Begin		 
    EXEC sp_configure 'Database Mail XPs', 1
    Reconfigure
  End  

  DECLARE 
    @profile_name sysname
  , @account_name sysname
  , @SMTP_servername sysname
  , @email_address NVARCHAR(128)
  , @display_name NVARCHAR(128)
  , @rv INT
  

  -- Set profil name here
  SET @profile_name = 'YourSQLDba_EmailProfile';

  SET @account_name = lower(replace(convert(sysname, Serverproperty('servername')), '\', '.'))

  -- Init email account name
  If @sourceEmail = ''
  Begin
    SET @email_address = lower(@account_name+'@YourSQLDba.com')
    SET @display_name = lower(convert(sysname, Serverproperty('servername'))+' : YourSQLDba ')
  End  
  Else
  Begin
    SET @email_address = @sourceEmail
    SET @display_name = @sourceEmail
  End  
    

  -- if account exists remove it
  If Exists (Select * From msdb.dbo.sysmail_account WHERE name = @account_name )
  Begin
    Exec @rv = msdb.dbo.sysmail_delete_account_sp  @account_name = @account_name
    If @rv <> 0 
    Begin  
      Raiserror('Cannot remove existing database mail account (%s)', 16, 1, @account_Name);
      return
    End
  End;

  -- if profile exists remove it
  If Exists (Select * From msdb.dbo.sysmail_profile WHERE name = @profile_name)
  Begin
    Exec @rv = msdb.dbo.sysmail_delete_profile_sp @profile_name = @profile_name
    If @rv <> 0 
    Begin  
      Raiserror('Cannot remove existing database mail profile (%s)', 16, 1, @profile_name);
      return
    End
  End

  -- Proceed email config in a single tx to leave nothing inconsistent
  Begin transaction ;

  -- Add the account
  Exec @rv = msdb.dbo.sysmail_add_account_sp
    @account_name = @account_name
  , @email_address = @email_address
  , @display_name = @display_name
  , @mailserver_name = @SmtpMailServer
  , @port = @SmtpMailPort
  , @enable_ssl = @SmtpMailEnableSSL
  , @username = @EmailServerAccount
  , @password = @EmailServerPassword;

  If @rv<>0
  Begin
    Raiserror('Failure to create database mail account (%s).', 16, 1, @account_Name) ;
    return
  End

  declare @profileId Int

  -- Add the profile
  Exec @rv = msdb.dbo.sysmail_add_profile_sp @profile_name = @profile_name

  If @rv<>0
  Begin
    Raiserror('Failure to create database mail profile (%s).', 16, 1, @profile_Name);
 	  Rollback transaction;
    return
  End;

  -- Associate the account with the profile.
  Exec @rv = msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name = @profile_name
  , @account_name = @account_name
  , @sequence_number = 1 ;

  If @rv<>0
  Begin
    Raiserror('Failure when adding account (%s) to profile (%s).', 16, 1, @account_name, @profile_Name) ;
 	  Rollback transaction;
    return
  End;

  COMMIT transaction;
  
  EXEC msdb.dbo.sp_set_sqlagent_properties @email_save_in_sent_folder = 1
  EXEC master.dbo.xp_instance_regwrite 
    N'HKEY_LOCAL_MACHINE'
  , N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent'
  , N'UseDatabaseMail'
  , N'REG_DWORD'
  , 1
  EXEC master.dbo.xp_instance_regwrite 
    N'HKEY_LOCAL_MACHINE'
  , N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent'
  , N'DatabaseMailProfile'
  , N'REG_SZ'
  , @profile_Name

  Declare @NetStop sysname
  Declare @SqlAgentServiceName sysname
  Set @SqlAgentServiceName = convert(sysname, Serverproperty('instancename'))
  If @SqlAgentServiceName IS NOT NULL
    Set @NetStop = 'Net Stop "SQLAgent$'+@SqlAgentServiceName+'"'
  Else 
    Set @NetStop = 'Net Stop SQLSERVERAGENT '
    
  Declare @NetStart sysname
  If @SqlAgentServiceName IS NOT NULL
    Set @NetStart = 'Net Start "SQLAgent$'+@SqlAgentServiceName+'"'
  Else 
    Set @NetStart = 'Net Start SQLSERVERAGENT '
  
  -- If XP_cmdshell is activated temporary to restart automatically SQL Agent
  Exec yMaint.SaveXpCmdShellStateAndAllowItTemporary 
  
  Begin try -- intercepte erreurs pour être sur que restore va se faire
    Select 'Review your job parameters if job already existed ' As Msg
    print  @netstop
    EXEC xp_cmdShell @netStop, 'NO_OUTPUT'

    print  @netstart
    EXEC xp_cmdShell @netStart, 'NO_OUTPUT'
  end try 
  begin catch
    declare @error nvarchar(max)
    set @error = str(error_number()) + ERROR_MESSAGE ()
    print @error
  end catch 
  
  Exec yMaint.RestoreXpCmdShellState 
  
  DECLARE @retval INT
  SELECT @retval = 0
  while (1=1)
  Begin
    EXECUTE master.dbo.xp_sqlagent_is_starting @retval OUTPUT
    If @retval <> 1 Break

    print 'SQL Server Agent is starting. InitialSetupOfYourSqlDba is waiting for 1 second.'
    waitfor delay '00:00:01'
  end  

  If exists(SELECT * FROM msdb.dbo.sysoperators Where name = @oper)
    Exec msdb.dbo.sp_delete_operator @name = @oper;
    
  Exec msdb.dbo.sp_add_operator @name = @oper, @email_address = @email

  Declare @pathBkp Nvarchar(512);
  Exec master.dbo.xp_instance_regread 
      N'HKEY_LOCAL_MACHINE'
    , N'Software\Microsoft\MSSQLServer\MSSQLServer'
    , N'BackupDirectory'
    , @pathBkp OUTPUT
    , 'no_output'

  -- prendre répertoire SQL backup par défaut si pas complété
  Select @FullBackupPath = ISNULL(@FullBackupPath, @pathBkp), @LogBackupPath = ISNULL(@LogBackupPath, @pathBkp)

  Exec Install.AddOrReplaceMaintenance '', @FullBackupPath, @LogBackupPath, @FullMaintenanceScript, @LogBackupScript
   
End -- Install.InitialSetupOfYourSqlDba 
GO

-- This procedure removes from SQL Server Agent's jobs steps commands strings
-- which meets the selection criterias contained in 
-- @SelectSearchArg and @UnSelectSearchArg,
-- the parameter string supplied by the "@prm" parameter.
-- The parameter string must begin with a '@' character.
-- The removal begins from the '@' character and ends before the next '@' character 
-- or at the end of the command string in the jobstep.
Exec f$.DropObj 'yInstall.CleanUpParam'
GO
Create proc yInstall.CleanUpParam
  @prm sysname
, @SelectSearchArg nvarchar(1000) 
, @UnSelectSearchArg nvarchar(1000) = ''
as
Begin
  Set nocount on 
  
  declare @sql nvarchar(max)
  declare @job_id uniqueidentifier
  declare @step_id int
  declare @pos int
  declare @PosDeb int
  declare @PosFin int

  While (1=1) -- while there is steps to correct
  Begin
    select @job_id=job_id, @step_id=step_id, @sql=command
    from msdb.dbo.sysjobsteps
    Where command like @SelectSearchArg
      And command not like @UnSelectSearchArg
      And command like '%'+@prm+'[^a-z0-9]%'
    If @@rowcount = 0 break

    set @pos = patindex('%'+@prm+'[^a-z0-9]%', @sql)

    -- assume the first parameter is always valid
    Set @PosDeb = @pos

    Set @PosFin = @pos+1
    While (substring(@sql, @PosFin,1) <> '@')
    Begin
      --print substring(@sql, @PosFin,1)
      Set @PosFin = @PosFin +1
      If @PosFin >= len(@Sql) Break
    End
    If substring(@sql, @PosFin,1) = '@'    
      Set @PosFin = @PosFin -1  -- place the end position before the '@' 
    -- if last param remove comma before if necessary
    If @PosFin >= len(@Sql)
    Begin
      While (substring(@sql, @Pos, 1) <> ',')
      Begin
        --print substring(@sql, @PosFin,1)
        Set @Pos = @Pos -1
        If @pos = 1 Break
      End
      If @pos > 1 Set @PosDeb = @pos
    End

    Print '========================== Job step before update ============================'
    Print @sql
    Set @sql = Stuff(@sql, @PosDeb, @PosFin - @PosDeb + 1, '')
    Print '========================== Job step after update ============================'
    Print @sql
    Print '======================================================================'
    
    Update JS 
    Set command = @sql
    from msdb.dbo.sysjobsteps JS
    Where @job_id=job_id and @step_id=step_id

  End  
End -- yInstall.CleanUpParam
GO

Exec yInstall.CleanUpParam 
  @prm = '@genjour'
, @SelectSearchArg = '%YourSQLDba%@DoBackup = ''F''%'
Exec yInstall.CleanUpParam 
  @prm = '@NotifyMandatoryFullDbBkpBeforeLogBkp'
, @SelectSearchArg = '%YourSQLDba%@DoBackup = ''F''%'
Exec yInstall.CleanUpParam 
  @prm = '@genjour'
, @SelectSearchArg = '%YourSQLDba%@DoBackup = ''L''%'

Begin
  -- remove comments prededing the @jobId parameter from YourSQLDba_DoMaint calls in SQL Server Agent
  Update JS 
  Set command = replace( command 
                       , '-- Agent job number to track step to retrieve step script in maintenance report'
                       , '')
  from msdb.dbo.sysjobsteps JS
  Where command like '%YourSQLDba_DoMaint%-- Agent job number to track step to retrieve step script in maintenance report%'

  -- remove @jobId parameter from YourSQLDba_DoMaint calls in SQL Server Agent
  Exec yInstall.CleanUpParam 
    @prm = '@jobId'
  , @SelectSearchArg = '%YourSQLDba_DoMaint%$(ESCAPE_NONE(JOBID))%'
End

-- remove @jobId parameter and comments from DeleteOldBackups calls in SQL Server Agent
Exec yInstall.CleanUpParam 
  @prm = '@jobId'
, @SelectSearchArg = '%YourSQLDba.Maint.DeleteOldBackups%@JobId%=%$(ESCAPE_NONE(JOBID))%'

Begin
  -- remove comments prededing the @StepId parameter from YourSQLDba_DoMaint calls in SQL Server Agent
  Update JS 
  Set command = replace( command 
                       , '-- Agent job step number to track step to retrieve step script in maintenance report'
                       , '')
  from msdb.dbo.sysjobsteps JS
  Where command like '%%YourSQLDba_DoMaint%-- Agent job step number to track step to retrieve step script in maintenance report%'

  -- remove @StepId parameter from YourSQLDba_DoMaint calls in SQL Server Agent
  Exec yInstall.CleanUpParam 
    @prm = '@StepId'
  , @SelectSearchArg = '%YourSQLDba_DoMaint%$(ESCAPE_NONE(STEPID))%'
End

-- remove @StepId parameter and comments from DeleteOldBackups calls in SQL Server Agent
Exec yInstall.CleanUpParam 
  @prm = '@StepId'
, @SelectSearchArg = '%YourSQLDba.Maint.DeleteOldBackups%@StepId%=%$(ESCAPE_NONE(STEPID))%'
GO

Exec f$.DropObj 'yInstall.AddUpEndParam'
GO
Create proc yInstall.AddUpEndParam
  @SelectSearchArg nvarchar(1000) 
, @UnSelectSearchArg nvarchar(1000)
, @prm nvarchar(1000)
as
Begin
  Set nocount on 
  
  declare @sql varchar(max)
  declare @job_id uniqueidentifier
  declare @step_id int
  declare @pos int
  declare @PosDeb int
  declare @PosFin int

  set @prm = yExecNLog.Unindent_TSQL(@prm) 

  While (1=1) -- while there is steps to correct
  Begin

    select @job_id=job_id, @step_id=step_id, @sql=command
    from msdb.dbo.sysjobsteps
    Where command like @SelectSearchArg
      And command not like @UnSelectSearchArg

    If @@rowcount = 0 break

    Print '========================== Job step before update ============================'
    Print @sql

    -- suppress trailing spaces, tabs and carrige return at the end of the sql statement
    While (1=1)
    Begin
      If substring(@sql,len(@sql), 1) not in (' ', char(10), char(13), char(9))
        Break

      Set @sql = substring(@sql, 1, len(@sql)-1)
    End 

    -- add params
    Set @sql = yExecNLog.Unindent_TSQL(@sql + @prm)
    Print '========================== Job step after update  ============================'
    Print @sql
    Print '======================================================================'
    
    Update JS 
    Set command = @sql
    from msdb.dbo.sysjobsteps JS
    Where @job_id=job_id and @step_id=step_id

  End  -- While there is steps to correct
End -- yInstall.AddUpEndParam
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Exec yInstall.AddUpEndParam
  @SelectSearchArg = '%exec Maint.YourSqlDba_DoMaint%@DoBackup = ''F''%'
, @UnSelectSearchArg = '%@ExcDbFromPolicy_CheckFullRecoveryModel%'
, @prm =
  '
  -- Each database exclusion filter must be on its own line between the following quote pair
  , @ExcDbFromPolicy_CheckFullRecoveryModel =
  ''
  '' 
  '
GO

print 'Existing installation, if any is updated to this version.'
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
exec f$.DropObj 'yInstall.ReplaceParamValue'
GO
-- This function replace the parameters name in the "@command" string
-- and subtract 1 day from the number of days of retention.
Create Function yInstall.ReplaceParamValue 
(
  @command nvarchar(max)
, @paramName sysname
, @newParamValue nvarchar(max) 
)
returns nvarchar(max)
as
Begin
  Declare @ParamPos int 
  Declare @equalPos int
  Declare @paramValuePos int 
  Declare @paramValueEndPos int 
  Declare @paramValueLength int 
  Declare @paramFullLength int 
  Declare @paramValue nvarchar(max) 
  Declare @cmdRep nvarchar(max) 

  Set @ParamPos = PATINDEX ('%'+@paramName+'[^a-z0-9_]%=%',@command)

  If @ParamPos = 0       -- the parameter is not in the command
    return (@command)

  Set @equalPos = @ParamPos 
                + PATINDEX('%=%', Substring(@command, @ParamPos, 4000)) - 1
  Set @paramValuePos = @equalPos 
                     + PATINDEX('%[0-9]%', Substring(@command, @equalPos, 4000)) - 1
  Set @paramValueEndPos = @paramValuePos 
                        + PATINDEX('%[^0-9]%', Substring(@command, @paramValuePos, 4000)) - 2
  Set @paramValueLength = @paramValueEndPos - @paramValuePos + 1
  Set @paramValue= substring(@command, @paramValuePos, @paramValueLength)
  Set @paramFullLength = @paramValueEndPos - @ParamPos + 1
  Set @cmdRep = Stuff ( @command
                      , @ParamPos
                      , @paramFullLength
                      , @ParamName + ' = '+ @newParamValue
                      )
  return (@cmdRep)
End -- yInstall.ReplaceParamValue
GO 

If Db_name() <> 'YourSqlDba' Use YourSqlDba
exec f$.DropObj 'yInstall.ReplaceRetDays'
GO
-- This function replace the parameters name in the "@command" string
-- and subtract 1 day from the number of days of retention.
Create Function yInstall.ReplaceRetDays 
(
  @command nvarchar(max)
, @paramName sysname
, @newParamName sysname
)
returns nvarchar(max)
as
Begin
  Declare @ParamPos int 
  Declare @equalPos int
  Declare @paramValuePos int 
  Declare @paramValueEndPos int 
  Declare @paramValueLength int 
  Declare @paramFullLength int 
  Declare @paramValue nvarchar(max) 
  Declare @newParamValue nvarchar(max) 
  Declare @cmdRep nvarchar(max) 

  Set @ParamPos = PATINDEX ('%'+@paramName+'[^a-z0-9_]%=%',@command)

  If @ParamPos = 0       -- the parameter is not in the command
    return (@command)

  Set @equalPos = @ParamPos 
                + PATINDEX('%=%', Substring(@command, @ParamPos, 4000)) - 1
  Set @paramValuePos = @equalPos 
                     + PATINDEX('%[0-9nN]%', Substring(@command, @equalPos, 4000)) - 1
  Set @paramValueEndPos = @paramValuePos 
                        + PATINDEX('%[^0-9nullNULL]%', Substring(@command, @paramValuePos, 4000)) - 2
  Set @paramValueLength = @paramValueEndPos - @paramValuePos + 1
  Set @paramValue= substring(@command, @paramValuePos, @paramValueLength)
  Set @paramFullLength = @paramValueEndPos - @ParamPos + 1
  Set @newParamValue = 
                       CASE 
                         When @paramValue = 'null'  Or @paramValue = 'NULL' Then 'NULL'
                         When @paramValue = '0' Then 'NULL'
                         Else convert(nvarchar(30) 
                                     ,CONVERT(int, @paramValue) - 1
                                     )
                       End
  Set @cmdRep = Stuff ( @command
                      , @ParamPos
                      , @paramFullLength
                      , @newParamName + ' = '+ @newParamValue
                      )
  return (@cmdRep)
End -- yInstall.ReplaceRetDays
GO 

Exec f$.DropObj 'Install.UpdateMaintenanceTasksParam'
GO
Create proc Install.UpdateMaintenanceTasksParam 
  @paramName sysname
, @paramValue nvarchar(max)
as
Begin
  Update msdb.dbo.sysjobsteps 
  Set 
    command = yInstall.ReplaceParamValue(command, @paramName, @paramValue )  
  Where command like '%'+'YourSQLDba_DoMaint%'+@paramName+'[^a-z0-9_]%'

End  -- Install.UpdateMaintenanceTasksParam
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yInstall.DoReplacesInJobAndTasks'
GO
Create proc yInstall.DoReplacesInJobAndTasks
  @search nvarchar(1000) 
, @replace nvarchar(1000) = ''
as
Begin
  Set nocount on 
  
  Set @search = replace(@search, '"', '''')
  Set @replace = replace(@replace, '"', '''')
  
  Update JS 
  Set JS.step_name = replace (js.step_name, @search, @replace)
  from msdb.dbo.sysjobsteps JS
  Where step_name like '%'+@search+'%'

  Update JS 
  Set command = replace(command, @search, @replace)
  from msdb.dbo.sysjobsteps JS
  Where command like '%'+@search+'%'

  Update JS 
  Set JS.output_file_name = replace (js.output_file_name, @search, @replace)
  from msdb.dbo.sysjobsteps JS
  Where output_file_name like '%'+@search+'%'

  Update J 
  Set J.name = replace(J.name, @search, @replace)
  from msdb.dbo.sysjobs J
  Where name like '%'+@search+'%'

  Update J 
  Set description = replace(description, @search, @replace)
  from msdb.dbo.sysjobs J
  Where description like '%'+@search+'%'

  Update OP
    Set OP.name = replace(name, @search, @replace)
  From msdb.dbo.sysoperators OP
  Where name like '%'+@search+'%'
  
End -- yInstall.DoReplacesInJobAndTasks
GO

-- script to migrate previous YourSQLDba database to YourSqlDba

SET NOCOUNT ON 

--Select  
--  yInstall.ReplaceRetDays(command, '@FullBkpRet', '@FullBkpRetDays') 
--From msdb.dbo.sysjobsteps 
--Where command like '%'+'Maint.YourSqlDba_DoMaint%@FullBkpRet'+'[^a-z0-9_]%'

-- version 4.0.10
Exec yInstall.DoReplacesInJobAndTasks '@UpdStatDaySpread', '@SpreadUpdStatRun'

Update msdb.dbo.sysjobsteps 
Set 
  command = yInstall.ReplaceRetDays(command, '@FullBkpRet', '@FullBkpRetDays')  
Where command like '%'+'Maint.YourSqlDba_DoMaint%@FullBkpRet'+'[^a-z0-9_]%'

--Select  
--  yInstall.ReplaceRetDays(command, '@LogBkpRet', '@LogBkpRetDays') 
--From msdb.dbo.sysjobsteps 
--Where command like '%'+'Maint.YourSqlDba_DoMaint%@LogBkpRet'+'[^a-z0-9_]%'

Update msdb.dbo.sysjobsteps 
Set 
  command = yInstall.ReplaceRetDays(command, '@LogBkpRet', '@LogBkpRetDays')  
Where command like '%'+'Maint.YourSqlDba_DoMaint%@LogBkpRet'+'[^a-z0-9_]%'

--Select  
--  yInstall.ReplaceRetDays(command, '@BackupRetentionDaysForSelectedDb', '@BkpRetDays') 
--From msdb.dbo.sysjobsteps 
--Where command like '%'+'Maint.DeleteOldBackups%@BackupRetentionDaysForSelectedDb'+'[^a-z0-9_]%'

Update msdb.dbo.sysjobsteps 
Set 
  command = yInstall.ReplaceRetDays(command, '@BackupRetentionDaysForSelectedDb', '@BkpRetDays')  
Where command like '%'+'Maint.DeleteOldBackups%@BackupRetentionDaysForSelectedDb'+'[^a-z0-9_]%'

--Select  
--  yInstall.ReplaceRetDays(command, '@BackupRetentionDays', '@BkpRetDaysForUnSelectedDb') 
--From msdb.dbo.sysjobsteps 
--Where command like '%'+'Maint.DeleteOldBackups%@BackupRetentionDays'+'[^a-z0-9_]%'


Update msdb.dbo.sysjobsteps 
Set 
  command = yInstall.ReplaceRetDays(command, '@BackupRetentionDays', '@BkpRetDaysForUnselectedDb')  
Where command like '%'+'Maint.DeleteOldBackups%@BackupRetentionDays'+'[^a-z0-9_]%'


Exec yInstall.DoReplacesInJobAndTasks '@MaxFailedBackupAttemptsToOffline', '@ConsecutiveFailedbackupsDaysToPutDbOffline'

-- Version 6.2.3
Exec yInstall.DoReplacesInJobAndTasks '@ConsecutiveFailedbackupsDaysToPutDbOffline', '@ConsecutiveDaysOfFailedBackupsToPutDbOffline'
GO  
-- ------------------------------------------------------------------------------
-- Create network map table
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO

-- if the table doesn't exists create the latest version
If object_id('Maint.NetworkDrivesToSetOnStartup') is null 
Begin
  Declare @sql nvarchar(max)
  Set @sql =
  '
  Create table  Maint.NetworkDrivesToSetOnStartup
  (
    DriveLetter       nchar(2) 
  , Unc          nvarchar(255) 
  , constraint Pk_NetworkDrivesToSetOnStartup 
    primary key  clustered (DriveLetter)
  )
  '
  Exec yExecNLog.QryReplace @sql output, '"', ''''
  Exec (@sql)

  If Object_Id('tempdb..##NetworkDrivesToSetOnStartup') IS NOT NULL
    Exec
    (
    '
    Insert Into Maint.NetworkDrivesToSetOnStartup ([DriveLetter],[Unc]) 
    Select [DriveLetter],[Unc]
    From ##NetworkDrivesToSetOnStartup
    Drop table ##NetworkDrivesToSetOnStartup
    '
    )
End
GO

-- ------------------------------------------------------------------------------
-- Stored procedure to define network drive on SQL Server startup
-- ------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO

Exec f$.DropObj 'Maint.CreateNetworkDrives'
GO
Create proc Maint.CreateNetworkDrives 
  @DriveLetter nvarchar(2) 
, @unc nvarchar(255) 
as
Begin
  Declare @errorN int
  Declare @cmd nvarchar(4000)

  Set nocount on

  Exec yMaint.SaveXpCmdShellStateAndAllowItTemporary 

  Set @DriveLetter=rtrim(@driveLetter)
  Set @Unc=rtrim(@Unc)

  If Len(@DriveLetter) = 1
    Set @DriveLetter = @DriveLetter + ':'

  If Len(@Unc) >= 1
  Begin
    Set @Unc = yUtl.NormalizePath(@Unc)
    Set @Unc = Stuff(@Unc, len(@Unc), 1, '')
  End

  Set @cmd = 'net use <DriveLetter> /Delete'
  Set @cmd  = Replace( @cmd, '<DriveLetter>', @DriveLetter)
  

  begin try 
    Print @cmd
    exec xp_cmdshell @cmd, no_output
  end try 
  begin catch 
  end catch

  -- suppress previous network drive definition
  If exists(select * from Maint.NetworkDrivesToSetOnStartup Where DriveLetter = @driveLetter)
  Begin
    Delete from Maint.NetworkDrivesToSetOnStartup Where DriveLetter = @driveLetter
  End

  Begin Try
    
    Set @cmd = 'net use <DriveLetter> <unc>'
    Set @cmd  = Replace( @cmd, '<DriveLetter>', @DriveLetter )
    
    Set @cmd  = Replace( @cmd, '<unc>', @unc )
    Print @cmd
    exec xp_cmdshell @cmd

    Insert Into Maint.NetworkDrivesToSetOnStartup (DriveLetter, Unc) Values (@DriveLetter, @unc)
    
    Exec yMaint.RestoreXpCmdShellState 

  End Try
  Begin Catch
    Set @errorN = ERROR_NUMBER() -- return error code
    Print convert(nvarchar, @errorN) + ': ' + ERROR_MESSAGE() 
    Exec yMaint.RestoreXpCmdShellState 
  End Catch

End -- Maint.CreateNetworkDrives
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO

Exec f$.DropObj 'Maint.DisconnectNetworkDrive'
GO
Create proc Maint.DisconnectNetworkDrive 
  @DriveLetterOrUNC nvarchar(255) 
As 
Begin
  Declare @errorN int
  Declare @DriveLetter nvarchar(255)
  Declare @cmd nvarchar(4000)

  Set nocount on

  If Len(@DriveLetterOrUNC) = 1
    Set @DriveLetterOrUNC = @DriveLetterOrUNC + ':'

  Set @DriveLetterOrUNC = yUtl.NormalizePath(@DriveLetterOrUNC)

  -- because on past relaxed parameter validation the table may have variant of drive letter or unc format.
  -- make it uniform to make the rest of the code to work properly.
  ;With 
    UpdateView as
    (
    Select 
      DriveLetter
    , Unc
    , left(yUtl.NormalizePath(left(rtrim(DriveLetter)+':', 2)),2) as NormalizedDriveLetter
    , Stuff(yUtl.NormalizePath(rtrim(Unc)), len(yUtl.NormalizePath(rtrim(Unc))), 1, '') as NormalizedUnc
    From Maint.NetworkDrivesToSetOnStartup
    )
  Update UpdateView Set DriveLetter = NormalizedDriveLetter, Unc = NormalizedUnc

  -- no matter how drive letter or unc where stored with or without ending '\', make it work
  Set @DriveLetter = Null
  Select @DriveLetter = DriveLetter
  From Maint.NetworkDrivesToSetOnStartup
  Where DriveLetter = left(@DriveLetterOrUNC,2)
     Or Unc = @DriveLetterOrUNC

  If @DriveLetter Is Not Null
  Begin
    Begin Try
      
      Set @cmd = 'net use <DriveLetter> /DELETE'
      Set @cmd  = Replace( @cmd, '<DriveLetter>', @DriveLetter )
    
      Print @cmd
      exec yMaint.SaveXpCmdShellStateAndAllowItTemporary 
      exec xp_cmdshell @cmd
      exec yMaint.RestoreXpCmdShellState  

    Delete From Maint.NetworkDrivesToSetOnStartup
    Where DriveLetter = left(yUtl.NormalizePath(@DriveLetterOrUNC),2)
       Or Unc = yUtl.NormalizePath(@DriveLetterOrUNC)

    End Try
    Begin Catch
      Set @errorN = ERROR_NUMBER() -- return error code
      Print convert(nvarchar, @errorN) + ': ' + ERROR_MESSAGE() 
      exec yMaint.RestoreXpCmdShellState  
    End Catch

  End

  Else
  Begin
    Print 'No network drive match this criteria.  '
        + 'Run the following command to list existing network drives :'
        + ' «Exec YourSQLDba.Maint.ListNetworkDrives»'
  End
  
End -- Maint.DisconnectNetworkDrive
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Exec f$.DropObj 'Maint.ListNetworkDrives'
GO

Create proc Maint.ListNetworkDrives 
As 
Begin

  Set nocount on

  Select DriveLetter, Unc
  From Maint.NetworkDrivesToSetOnStartup

End -- Maint.ListNetworkDrives
GO


If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
If object_id('yMirroring.InactivateYourSqlDbaJobs') is not null 
  drop proc yMirroring.InactivateYourSqlDbaJobs
GO
Create Procedure yMirroring.InactivateYourSqlDbaJobs
As
Begin
 
 Select ROW_NUMBER() OVER (ORDER BY job_id) As Seq, job_id 
 Into #jobs
 From msdb.dbo.sysjobsteps 
 Where command like '%YourSQLDba_DoMaint%'

 Declare @job_id uniqueidentifier
 Declare @sql nvarchar(max)
 Declare @seq int

 Set @seq = 0

 while 1=1
 Begin

   Select Top 1 @Seq=Seq, @job_id=job_id
   From #jobs
   Where Seq > @Seq

   If @@rowcount = 0
     break

   Set @sql = 'msdb.dbo.sp_update_job "<job_id>", @enabled= 0'
   Set @sql = Replace( @sql, '<job_id>', convert(nvarchar(36), @job_id))
   Set @sql = Replace( @sql, '"', '''')

   --Print @sql
   Exec( @sql )
 End

 Drop table #jobs

End -- yMirroring.InactivateYourSqlDbaJobs
GO

Exec f$.DropObj 'Mirroring.DropServer' 
GO
Create Procedure Mirroring.DropServer
  @MirrorServer sysname = ''
, @silent int = 0  
As
Begin
  Declare @sql nvarchar(max)
  Declare @remoteServerYourSqlDbaVersion Nvarchar(40)
  Declare @ObjectId int

  Set NoCount on

  Exec yMirroring.ReportYourSqlDbaVersionOnTargetServers 
    @MirrorServer = @MirrorServer
  , @remoteVersion = @remoteServerYourSqlDbaVersion Output
  , @LogToHistory = 0
  , @silent = @silent

  If @remoteServerYourSqlDbaVersion IN ('Server undefined', 'Remote YourSqlDba is missing)' )
    Return 

  Delete From Mirroring.TargetServer Where MirrorServerName=@MirrorServer
  
  Declare @srvLogins Table (loginName sysname primary key clustered)
  Insert into @srvLogins
  select p.name
  from 
    sys.servers S
    Join
    sys.Linked_logins L
    ON L.server_Id = S.server_id 
    Join 
    sys.server_principals P
    On P.principal_id = l.local_principal_id
  Where S.name = @MirrorServer 
    And S.is_linked = 1
  
  EXEC master.dbo.sp_droplinkedsrvlogin @rmtsrvname=@MirrorServer,@locallogin=NULL

  Declare @name sysname -- drop dependants logins for this linked server
  Set @name = '' -- otherwise the linked server is not removed
  While(1=1)
  Begin 
    Select top 1 @name = loginName from @SrvLogins Where loginName > @name Order by loginName
    If @@ROWCOUNT = 0 break
    Print 'Remove existing linked server login '+@name
    Exec sp_droplinkedsrvlogin @MirrorServer, @name
  End

  -- Set options for the linked server to be able to do Exec ... AT
  EXEC master.dbo.sp_serveroption @server=@MirrorServer, @optname=N'rpc', @optvalue=N'true'
  EXEC master.dbo.sp_serveroption @server=@MirrorServer, @optname=N'rpc out', @optvalue=N'true'

  Print 'Remove existing Linked Server' + @mirrorServer
  Exec sp_dropServer @MirrorServer
  
  Print '-------------------------------------------------------------------' 
  Print ' Mirror server succesfully uninstalled' 
  Print '-------------------------------------------------------------------' 
  
End -- Mirroring.DropServer
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Exec f$.DropObj 'Mirroring.AddServer' 
GO
Create Procedure Mirroring.AddServer 
  @MirrorServer nvarchar(512)
, @remoteLogin nvarchar(512)
, @remotePassword nvarchar(512)
, @ExcSysAdminLoginsInSync int = 0
, @ExcLoginsFilter nvarchar(max) = ''
, @MirrorServerDataSrc nvarchar(512) = ''
, @YourSqlDbaAccountForMirroringPwd nvarchar(512) = NULL
As
Begin
  Declare @sql nvarchar(max)
  Declare @Info nvarchar(2048) 
  Declare @remoteServerYourSqlDbaVersion nvarchar(100)

  Set NoCount on
     
  -- Create a link server for the Mirror
  
  If Exists (Select * From sys.servers where name = @MirrorServer And is_linked = 1)
  Begin
    EXEC Mirroring.DropServer @MirrorServer
  End  

  -- Get SqlAgent Login Account
  Declare @SqlAgentLoginAccount as sysname
  select @SqlAgentLoginAccount = login_name from sys.dm_exec_sessions Where program_name = 'SQLAgent - Generic Refresher'
  If @@rowcount = 0 
  Begin
    Raiserror('SqlAgent must be running in order to identify its starting account and authorize it to the remote server', 11, 1)
    Return
  End

  IF (LEN(@MirrorServerDataSrc) > 0)
  BEGIN
    EXEC master.dbo.sp_addlinkedserver @server = @MirrorServer, @srvproduct='', @provider='SQLNCLI', @datasrc=@MirrorServerDataSrc
  END
  ELSE
  BEGIN
    EXEC master.dbo.sp_addlinkedserver @server = @MirrorServer, @srvproduct=N'SQL Server'
  END

  EXEC master.dbo.sp_addlinkedsrvlogin @rmtsrvname = @MirrorServer, @locallogin = NULL , @useself = N'True'

  -- enable SQLAgent to run remotely something AT the mirror server
  Print 'Adding delegate account "'+@remoteLogin+ '" for SQL Agent Login account : "'+@SqlAgentLoginAccount+'"'
  If left(@SqlAgentLoginAccount, 2)= '.\'
  Begin 
    Set @SqlAgentLoginAccount = STUFF(@SqlAgentLoginAccount, 1, 1, convert(sysname, serverproperty('machineName')))
  End  

  EXEC master.dbo.sp_addlinkedsrvlogin 
    @rmtsrvname = @MirrorServer
  , @locallogin = @SqlAgentLoginAccount
  , @useself = N'False'
  , @rmtUser = @RemoteLogin
  , @rmtPassWord = @RemotePassWord

  -- add also yourself for debugging purposes (to check the linkServer access)
  -- unless already done 
  Declare @localLogin sysname
  Set @localLogin = SUSER_SNAME()
  If @localLogin <> @SqlAgentLoginAccount And @localLogin <> 'YourSQLDba'
  Begin
    Print 'Adding delegate account "'+@remoteLogin+ '" for account "'+@localLogin+'"'
    EXEC master.dbo.sp_addlinkedsrvlogin 
      @rmtsrvname = @MirrorServer
    , @locallogin = @localLogin
    , @useself = N'False'
    , @rmtUser = @RemoteLogin
    , @rmtPassWord = @RemotePassWord
  End

  -- Set options for the linked server
  EXEC master.dbo.sp_serveroption @server=@MirrorServer, @optname=N'rpc', @optvalue=N'true'
  EXEC master.dbo.sp_serveroption @server=@MirrorServer, @optname=N'rpc out', @optvalue=N'true'
  EXEC master.dbo.sp_serveroption @server=@MirrorServer, @optname=N'query timeout', @optvalue=N'86400'
  
  Insert Into Mirroring.TargetServer (MirrorServerName ) 
  Select @MirrorServer 
  Where Not Exists (Select * From Mirroring.TargetServer Where MirrorServerName=@MirrorServer)

  -- if user specify a YourSqlDba password, it is set locally and remotely to the specified value
  Exec Mirroring.SetYourSqlDbaAccountForMirroring @YourSqlDbaAccountForMirroringPwd;

  Exec yMirroring.ReportYourSqlDbaVersionOnTargetServers 
    @MirrorServer = @MirrorServer
  , @remoteVersion = @remoteServerYourSqlDbaVersion Output
  , @LogToHistory = 0
  If @remoteServerYourSqlDbaVersion <> (Select v.VersionNumber from Install.VersionInfo () as v)
  Begin 
    Delete Mirroring.TargetServer Where MirrorServerName=@MirrorServer

    Print '************ AddServer Failure **********************'
    If @remoteServerYourSqlDbaVersion <> 'no remote mapping exists'
    Begin
      Print 'YourSqlDba.Mirror.AddServer : Problem occurred with linked server YourSqlDba Database version: '+@remoteServerYourSqlDbaVersion
      Print 'Install or Upgrade YourSqlDba on the remote server and run Mirroring.AddServer again'
      Print 'Rollbacking remote server addition because YourSqlDba version mismatch between local server and linked server'
      EXEC Mirroring.DropServer @MirrorServer, @silent = 1
    End
    Else 
    Begin
      Print 'YourSqlDba.Mirror.AddServer : Problem occurred: '+@remoteServerYourSqlDbaVersion
      Print 'Adjust Linked server remote logins mapping. Then test link server connection by browsing linked server databases '
      Print 'You can also do YourSqlDba.Mirror.DropServer followed by YourSqlDba.Mirror.AddServer with checking for proper remote user and password '
    End
    Print '*****************************************************'
    Raiserror ('See print text for Mirroring.Addserver failure',11,1)
    Return
  End
  
  -- Synchronise logins on the mirror server
  Exec yMirroring.LaunchLoginSync @MirrorServer=@MirrorServer
  
  Print '-------------------------------------------------------------------' 
  Print ' Mirror server succesfully installed' 
  Print '-------------------------------------------------------------------' 

End -- Mirroring.AddServer
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMirroring.DoRestore' 
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
Create Procedure yMirroring.DoRestore 
  @BackupType nchar(1)
, @Filename nvarchar(255)
, @DbName nvarchar(255)
, @ReplaceSrcBkpPathToMatchingMirrorPath nvarchar(max) = ''
, @ReplacePathsInDbFileNames nvarchar(max) = ''
As
Begin

  Declare @pathData nvarchar(512)
  Declare @pathLog nvarchar(512)
  Declare @FileType char(1)
  Declare @sql nvarchar(max)
  Declare @sqlcmd nvarchar(max)
  Declare @FileId int
  Declare @NoSeq int
  Declare @LogicalName sysname
  Declare @PhysicalName sysname
  Declare @NewPhysicalName sysname
  Declare @ClauseMove nvarchar(max)
  Declare @Position smallint
  Declare @ErrorMessage nvarchar(2048) 
  Declare @ReplSrch nvarchar(512)
  Declare @ReplBy nvarchar(512)
  
  Set nocount on

  If @ReplacePathsInDbFileNames = '' -- user did not specified any relocation parameter for DB files, so use default location
  Begin 
    -- get default data and log location
		  Exec master.dbo.xp_instance_regread 
		    N'HKEY_LOCAL_MACHINE'
		  , N'Software\Microsoft\MSSQLServer\MSSQLServer'
		  , N'DefaultData'
		  , @pathData OUTPUT
		  Exec master.dbo.xp_instance_regread 
		    N'HKEY_LOCAL_MACHINE'
		  , N'Software\Microsoft\MSSQLServer\MSSQLServer'
		  , N'DefaultLog'
		  , @pathLog OUTPUT

    -- if default data and log locations are not specified in server properties, use model database files locations
    If @pathData Is Null
      Select Top 1 @pathData = Left( physical_name, Len(physical_name) - Charindex('\', Reverse(physical_name))) 
      FROM model.sys.database_files 
      Where type = 0

    If @pathLog Is Null
      Select Top 1 @pathLog = Left( physical_name, Len(physical_name) - Charindex('\', Reverse(physical_name))) 
      FROM model.sys.database_files 
      Where type = 1
  End
  Else   -- user did specified replacement parameter for database files location
  Begin
    -- extract file path string replacement to do if any, because directories can be at a different places
    -- Parameter contains both search and replace parameter in the form  
    /*
       'stringToSearch1>StringToReplace1|
       stringToSearch2>StringToReplace2' 
    */
    -- where '>' is the divider of the pair. Each pair must be on its own line and ends with '|'
    -- Parameter can be empty 
    Set @ReplacePathsInDbFileNames = replace(@ReplacePathsInDbFileNames, '&GT;', '>')

    Declare @ReplacesOnFiles Table (seqRep int primary key, replSrch nvarchar(512) NULL, replBy nvarchar(512) NULL)
    ;With 
       ReplacePairs as (Select * From yUtl.SplitParamInRows (@ReplacePathsInDbFileNames) as x)
     , Pairs(seq, pair, posSep) as (Select no, line, CHARINDEX ('>', line) From ReplacePairs)
    insert @ReplacesOnFiles (seqRep, replSrch, replBy)
    Select seq, left(pair, posSep-1), right(pair, len(pair)-posSep) From pairs Where posSep > 1
  End
    
  -- If user specified a restore location remapping performs replacements on backup file name.
  If @ReplaceSrcBkpPathToMatchingMirrorPath <> ''
  Begin 
    -- extract replacement information on backup location to restore location
    -- on one side it is a network path and on the other it is a local path
    -- or it could but 2 network path expressed differently.
    -- Parameter contains both search and replace parameter in the form  
    /*
       'stringToSearch1>StringToReplace1
       stringToSearch2>StringToReplace2' 
    */
    -- where '>' is the divider of the pair. Each pair must be on its own line
    -- Parameter can be empty 
    -- Since the all call of this command get through an xml message ">" becomes "&GT;" 
    -- so it must be turned back to >
    Set @ReplaceSrcBkpPathToMatchingMirrorPath = replace(@ReplaceSrcBkpPathToMatchingMirrorPath, '&GT;', '>')

    Declare @ReplacesOnRestorePath Table (seqRep int primary key, replSrch nvarchar(512) NULL, replBy nvarchar(512) NULL)
    ;With 
      ReplacePairs as (Select * From yUtl.SplitParamInRows (@ReplaceSrcBkpPathToMatchingMirrorPath) as x)
    , Pairs(seq, pair, posSep) as (Select no, line, charindex('>', Line) From ReplacePairs)
    Insert @ReplacesOnRestorePath (seqRep, replSrch, replBy)
    Select seq, left(pair, posSep-1), right(pair, len(pair)-posSep) From pairs Where posSep > 1

    -- process replaces on backup file name and path location
    Declare @seqRep Int
    Set @SeqRep = 0
    While (1=1)
    Begin
      Select top 1 @SeqRep = SeqRep, @ReplSrch = replSrch, @ReplBy = replBy
      From @ReplacesOnRestorePath 
      Where seqRep > @seqRep 
      Order by seqRep

      If @@rowcount = 0 Break
      Set @Filename = replace(@Filename, @replSrch, @replBy)
    End
  End
 
  Begin Try    

    -- an internal raiserror to collectBackup... procedure makes unnecessary to test return code
    -- in case of error it will jump to the catch block to be reported
    Exec yMaint.CollectBackupHeaderInfoFromBackupFile @Filename
  
    Exec yMaint.CollectBackupFileListFromBackupFile @Filename

    -- recover database name from datase backup file
    Select @DbName = DatabaseName
    From Maint.TemporaryBackupHeaderInfo 
    Where spid = @@spid

    If @BackupType='F'
    Begin
      -- If database already exists with a status different than «RESTORING»
      -- we must generate an error to prevent restoring over a good database  
      If     DATABASEPROPERTYEX(@DbName, 'Status' ) Is Not Null 
         And DATABASEPROPERTYEX(@DbName, 'Status' ) <> 'RESTORING'
      Begin
        Raiserror (N'To restore a full backup to the mirror server the database %s must be in «RESTORING» state or not exists', 11, 1, @DbName)
      End

      -- previous database must be removed to have accurate information abut its last_lsn in msdb
      -- Generate restore command
      Set @sql = 
      '
       If databasepropertyex("<DbNameDest>", "status")="RESTORING"
       Begin
         Exec
         (
         "
         Restore Database [<DbNameDest>] with recovery;
         Drop DATABASE [<DbNameDest>];
         "
         )
       End;
       RESTORE DATABASE [<DbNameDest>]
       FROM DISK="<nomSauvegarde>" 
       WITH 
         <ClauseMove>
         ,CHECKSUM     
         ,REPLACE 
         ,NORECOVERY
      '

      Set @FileId = -1
      Set @NoSeq = 0

      -- generate the move command which is requiered where original location 
      -- from db source server don't match with destination location on destination server
      While 1=1
      Begin
        Select Top 1 
          @FileType = Type
        , @FileId = FileId
        , @LogicalName=LogicalName
        , @PhysicalName=PhysicalName 
        From Maint.TemporaryBackupFileListInfo 
        Where spid = @@spid And FileId > @FileId
        Order by FileId

        If @@rowcount = 0 break

        If @ReplacePathsInDbFileNames <> '' -- user specified relocation parameters
        Begin 
          -- check for replaces to do to "relocate" location 
          Set @SeqRep = 0
          While (1=1)
          Begin
            Select top 1 @SeqRep = SeqRep, @ReplSrch = replSrch, @ReplBy = replBy
            From @ReplacesOnFiles 
            Where seqRep > @seqRep 
            Order by seqRep

            If @@rowcount = 0 Break

            -- perform replacements as long as there are
            Set @PhysicalName = replace(@PhysicalName, @replSrch, @replBy)

          End -- while there is replacements on file names to perform

          Set @ClauseMove = 'MOVE "<logicalname>" TO "<physical_name>"'
          Set @ClauseMove = Replace( @ClauseMove, '<physical_name>', @PhysicalName )
          Set @ClauseMove = Replace( @ClauseMove, '<logicalname>', @LogicalName )
        End
        Else  
        Begin -- use default Db location parameters

          Set @ClauseMove = 'MOVE "<logicalname>" TO "<physical_path>\<physical_name>"'

          If @FileType = 'L' -- log location not usually the same that other files
            Set @ClauseMove = Replace( @ClauseMove, '<physical_path>', @pathLog )  --bug restore
          Else
            Set @ClauseMove = Replace( @ClauseMove, '<physical_path>', @pathData )

          -- strip the path out of physical name that comes from Maint.TemporaryBackupFileListInfo
          -- which is produced by CollectBackupHeaderInfoFromBackupFile

          Set @PhysicalName=RIGHT(@PhysicalName, Charindex('\', Reverse(@PhysicalName))-1) 
          Set @ClauseMove = Replace( @ClauseMove, '<physical_name>', @PhysicalName )
          Set @ClauseMove = Replace( @ClauseMove, '<logicalname>', @LogicalName )
        End
            
        Set @sql = Replace(@sql, '<ClauseMove>', @ClauseMove + nchar(13) + nchar(10) + '        ,<ClauseMove>') 
      End

      Set @sql = Replace(@sql, ',<ClauseMove>', '')
      Set @sql = replace (@sql, '"', '''')
      Set @sql = replace (@sql, '<DbNameDest>', @DbName)
      Set @sql = replace (@sql, '<nomSauvegarde>', @Filename)
      Set @sql = yExecNLog.Unindent_TSQL(@sql)
    End

    If @BackupType='D'
    Begin
      Set @sql = '<RestoreCmd>'
      Set @Position = 0
      
      -- To restore a log backup the database must exists and have the status «RESTORING»
      If    DATABASEPROPERTYEX(@DbName, 'Status' ) Is Null 
         Or DATABASEPROPERTYEX(@DbName, 'Status' ) <> 'RESTORING'
      Begin
        Raiserror (N'To restore a DIFFERENTIAL backup to the mirror server the database %s must be in «RESTORING» state', 11, 1, @DbName)
      End
         
      while 1=1
      Begin
        -- check database state to see which file of the log backup has to be restored
        -- funny enough restore database appears also in msdb.dbo.backupSet
        -- this information (position) is obtained through the last_lsn restore versus
        -- last_lsn into the backup

        Select Top 1 @Position = H.Position --first position that match the last_lsn
        From 
          (
          Select database_name, Max(last_lsn) as last_lsn
          From 
            msdb.dbo.backupset B 
          Group By database_name        
          ) X
          Join
          Maint.TemporaryBackupHeaderInfo H
          ON   H.spid = @@spid
           And H.DatabaseName = X.database_name collate database_default
           AND H.LastLSN > X.last_lsn
        Where H.Position > @Position
        Order By H.Position
        
        If @@rowcount = 0
          break
          
        -- Generate restore command.  
        -- Do not handle move command.  To acheive this there is an need to add column createLsn
        -- to Maint.TemporaryBackupFileListInfo and generate the move command only for the lsn
        -- that is between the backup lsn.  Also proceeed to replace in the file name.
        -- Some job but not overwhelming
        Set @sqlcmd = 
        'RESTORE DATABASE [<DbNameDest>]
         FROM DISK="<nomSauvegarde>" 
         WITH FILE=<Position>, NORECOVERY, CHECKSUM
        '    
        Set @sqlcmd = replace (@sqlcmd, '"', '''')
        Set @sqlcmd = replace (@sqlcmd, '<DbNameDest>', @DbName)
        Set @sqlcmd = replace (@sqlcmd, '<nomSauvegarde>', @Filename)
        Set @sqlcmd = replace (@sqlcmd, '<Position>', CONVERT(nvarchar(10), @Position))

        Set @sql = REPLACE( @sql, '<RestoreCmd>', @sqlcmd)
        Set @sql = @sql + char(10) + '<RestoreCmd>'
            
      End
      
      Set @sql = REPLACE( @sql, '<RestoreCmd>', '')
      
    End
    
    If @BackupType='L'
    Begin
      Set @sql = '<RestoreCmd>'
      Set @Position = 0
      
      -- To restore a log backup the database must exists and have the status «RESTORING»
      If    DATABASEPROPERTYEX(@DbName, 'Status' ) Is Null 
         Or DATABASEPROPERTYEX(@DbName, 'Status' ) <> 'RESTORING'
      Begin
        Raiserror (N'To restore a LOG backup to the mirror server the database %s must be in «RESTORING» state', 11, 1, @DbName)
      End
         
      while 1=1
      Begin
        -- check database state to see which file of the log backup has to be restored
        -- funny enough restore database appears also in msdb.dbo.backupSet
        -- this information (position) is obtained through the last_lsn restore versus
        -- last_lsn into the backup

        Select Top 1 @Position = H.Position --first position that match the last_lsn
        From 
          (
          Select database_name, Max(last_lsn) as last_lsn
          From 
            msdb.dbo.backupset B 
          Group By database_name        
          ) X
          Join
          Maint.TemporaryBackupHeaderInfo H
          ON   H.spid = @@spid
           And H.DatabaseName = X.database_name collate database_default
           AND H.LastLSN > X.last_lsn
        Where H.Position > @Position
        Order By H.Position
        
        If @@rowcount = 0
          break
          
        -- Generate restore command.  
        -- Do not handle move command.  To acheive this there is an need to add column createLsn
        -- to Maint.TemporaryBackupFileListInfo and generate the move command only for the lsn
        -- that is between the backup lsn.  Also proceeed to replace in the file name.
        -- Some job but not overwhelming
        Set @sqlcmd = 
        'RESTORE LOG [<DbNameDest>]
         FROM DISK="<nomSauvegarde>" 
         WITH FILE=<Position>, NORECOVERY, CHECKSUM
        '    
        Set @sqlcmd = replace (@sqlcmd, '"', '''')
        Set @sqlcmd = replace (@sqlcmd, '<DbNameDest>', @DbName)
        Set @sqlcmd = replace (@sqlcmd, '<nomSauvegarde>', @Filename)
        Set @sqlcmd = replace (@sqlcmd, '<Position>', CONVERT(nvarchar(10), @Position))

        Set @sql = REPLACE( @sql, '<RestoreCmd>', @sqlcmd)
        Set @sql = @sql + char(10) + '<RestoreCmd>'
            
      End
      
      Set @sql = REPLACE( @sql, '<RestoreCmd>', '')
      
    End
    
    If @sql <> ''
    Begin
      Declare @maxSeverity Int
      Declare @Msgs nvarchar(max)
      Exec yExecNLog.ExecWithProfilerTrace @sql, @maxSeverity output, @Msgs Output  
      If @maxseverity <=10 
      Begin
        Set @msgs = @sql + @msgs
        Exec yExecNLog.PrintSqlCode @msgs
      End
      Else
      Begin
        Raiserror (N'%s: %s %s', 11, 1, @@SERVERNAME, @Sql, @Msgs)    
      End
    End  
  End Try

  Begin Catch
    Select @ErrorMessage = ERROR_MESSAGE()
    Raiserror (N'yMirroring.DoRestore error / %s', 11, 1, @ErrorMessage )    
  End Catch
      
End -- yMirroring.DoRestore
GO
If Db_name() <> 'Master'  Use master
GO
-- previous version cleanup
if object_id('dbo.CreateNetworkDrive') is not null exec sp_procoption N'dbo.CreateNetworkDrive', N'startup', N'false'
If object_id('dbo.CreateNetworkDrive') is not null drop proc dbo.CreateNetworkDrive
GO
If object_id('YouSqlDbaAutostart_ReconnectNetworkDrive') is not null drop proc YouSqlDbaAutostart_ReconnectNetworkDrive
go
-- new version
If object_id('YourSqlDbaAutostart_ReconnectNetworkDrive') is not null drop proc YourSqlDbaAutostart_ReconnectNetworkDrive
go
Create proc YourSqlDbaAutostart_ReconnectNetworkDrive
As
Begin
  -------------------------------------------------------------------
  -- The "YouSqlDbaAutostart_ReconnectNetworkDrive" procedure is part of YourSQLDba.
  -------------------------------------------------------------------
  Declare @DriveLetter nchar(2)
  Declare @unc nvarchar(255)
  Declare @cmd nvarchar(4000)
  Declare @sql nvarchar(4000)


  Set @DriveLetter = ''

  while 1=1
  Begin
    Select Top 1 @DriveLetter=DriveLetter, @unc=Unc
    From YourSQLDba.Maint.NetworkDrivesToSetOnStartup
    Where DriveLetter > @DriveLetter
    
    if @@ROWCOUNT = 0
      break
      
    Begin Try
      set @sql =
      '
      If Db_name() <> "YourSqlDba"  Use YourSqlDba
      Print @cmd
      exec YourSQLDba.yMaint.SaveXpCmdShellStateAndAllowItTemporary 
      exec xp_cmdshell @cmd, NO_OUTPUT
      exec YourSQLDba.yMaint.RestoreXpCmdShellState
      '
      Set @sql  = Replace( @Sql, '"', '''')

      Set @cmd = 'net use <DriveLetter> /Delete'
      Set @cmd  = Replace( @cmd, '<DriveLetter>', @DriveLetter )
      
      Exec sp_executeSql @Sql, N'@cmd nvarchar(4000)', @cmd
      
      Set @cmd = 'net use <DriveLetter> <unc>'
      Set @cmd  = Replace( @cmd, '<DriveLetter>', @DriveLetter )
      Set @cmd  = Replace( @cmd, '<unc>', @unc )
      Exec sp_executeSql @Sql, N'@cmd nvarchar(4000)', @cmd

    End Try
    Begin Catch
      declare @msg nvarchar(max)
      Set @msg = STR(error_number())+' '+ERROR_MESSAGE ()
      print @msg
      exec YourSQLDba.yMaint.RestoreXpCmdShellState
    End Catch
        
  End  
End -- YourSqlDbaAutostart_ReconnectNetworkDrive
GO  

exec sp_procoption N'YourSqlDbaAutostart_ReconnectNetworkDrive', N'startup', N'true'
GO

-- -------------------------------------------------------------------------
-- Prepare databases for upgrade by changing their names and doing a backup 
-- before upgrade.  Users are automatically kicked out of the database.
-- The goal in changing names is prevent other users or applications
-- or services to connect. The DBA needs to have a means to have exclusive
-- access to new datasource definitions or connect strings 
-- reflecting the new databases names.
-- Suffix supplied by @DbNameSuffixForMaintenance is 
-- added to the name of databases supplied by @dbList.  The backup
-- reflect the name of the new database name and is placed into the backup path.
-- Backup can be bypassed by supplying empty string to @PathOfBackupBeforeMaintenance 
-- but it is obviously not recommanded.
-- A little table with a  long name : "RecoveryModelBeforePrepDbForMaintenanceMode"
-- is used as its name implies to keep track of the database recovery model
-- so if the upgrade process changes it, it will be brought to its original state
-- after running ReturnDbToNormalUseFromMaintenanceMode
-- To minimize the increase in size of the log file during the upgrade, it is possible to 
-- set @SetRecoveryModeToSimple to 1.  Doing so will put the database into SIMPLE
-- recovery mode until the «ReturnDbToNormalUseFromMaintenanceMode» is called.
-- -------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.PrepDbForMaintenanceMode'
GO

Create Procedure Maint.PrepDbForMaintenanceMode 
  @DbList nVARCHAR(max) = '' -- @DbList : See comments later for further explanations
, @DbNameSuffixForMaintenance nvarchar(128)
, @PathOfBackupBeforeMaintenance nvarchar(512) = NULL 
, @SetRecoveryModeToSimple int = 0
as
Begin 
 
  Set nocount on    
  
  Set @DbNameSuffixForMaintenance= isnull(@DbNameSuffixForMaintenance, '')
  Set @PathOfBackupBeforeMaintenance = ISNULL (@PathOfBackupBeforeMaintenance, '')
  
  If Right(@PathOfBackupBeforeMaintenance ,1) = '\'
    Set @PathOfBackupBeforeMaintenance = 
        Left(@PathOfBackupBeforeMaintenance, len(@PathOfBackupBeforeMaintenance) - 1)
    
  Select d.name collate database_default as Dbname, bl.lastLogBkpFile, row_number() over (order by line) seq 
  into #Tmp
  From 
    yUtl.SplitParamInRows (@dbList) AS X
    
    join 
    master.sys.databases d
    on d.name = x.line collate database_default
    
    left join
    Maint.JobLastBkpLocations bl
    on bl.dbName = d.name collate database_default
    
  Where d.name Not Like ('%[_]' + replace(@DbNameSuffixForMaintenance, '_', '[_]'));


  Declare @name sysname
  Declare @sql nvarchar(max)
  Declare @seq int
  Declare @lastLogBkpFile nvarchar(512)
  Declare @msgErr nvarchar(max)
  
  Set @seq = 0

  While (1=1)
  Begin

    Select top 1 @name = DbName, @seq = seq, @lastLogBkpFile = lastLogBkpFile 
    from #Tmp Where seq > @seq Order by seq

    If @@rowcount = 0 break

    Begin Try

      Set @sql = 
      '
      If Db_name() <> "Master"  Use master;
      Update [YourSQLDba].[Maint].[JobLastBkpLocations] Set keepTrace=1 Where dbName="<db>"    
      If Not Exists (Select * From [<db>].sys.tables Where name="RecoveryModelBeforePrepDbForMaintenanceMode")
        Select convert(sysname, DATABASEPROPERTYEX ("<db>", "recovery")) as recovery_model_desc 
        Into [<db>].dbo.RecoveryModelBeforePrepDbForMaintenanceMode
	   
	     Alter database [<db>] Set Offline With Rollback  Immediate
      Alter database [<db>] Set ONLINE 
	     Alter database [<db>] MODIFY NAME = [<db>_<suffix>]
	     Alter database [<db>_<suffix>] Set MULTI_USER With Rollback  Immediate	 
      '
      Set @sql = replace(@sql, '<db>', @name)
      Set @sql = replace(@sql, '<suffix>', @DbNameSuffixForMaintenance)
      Set @sql = replace(@sql, '"', '''')
    
      --print @sql
      exec(@sql)
      Set @sql = 
      '
      use [<db>_<suffix>];

	     Begin Transaction PrepDbForMaintenanceMode With mark "Mark to point in time restore for RestoreDbAtStartOfMaintenanceMode"
      Update dbo.RecoveryModelBeforePrepDbForMaintenanceMode Set recovery_model_desc = recovery_model_desc
      Commit Transaction PrepDbForMaintenanceMode
      '
      Set @sql = replace(@sql, '<db>', @name)
      Set @sql = replace(@sql, '<suffix>', @DbNameSuffixForMaintenance)
      Set @sql = replace(@sql, '"', '''')
    
      --print @sql
      exec(@sql)
      
      Print @name + ' renamed to ' + @name + '_' + @DbNameSuffixForMaintenance + ' for maintenance'
    End Try
    Begin Catch
      Set @msgErr = @name + '> ' + ERROR_MESSAGE()
      Raiserror (N'%s', 11, 1, @msgErr)
    End Catch

    If @PathOfBackupBeforeMaintenance = '' And @lastLogBkpFile Is Null
    Begin
      Raiserror (N'The database has no log backups and you did not specified a value for parameter @PathOfBackupBeforeMaintenance so it will not be possible to restore the database state at the start of the maintenance in case of a failure of the maintenance process', 11, 1)
    End
    Else
    Begin
      Begin Try
        -- Always make a log backup if the database has a log backup file exists for this database
        If @lastLogBkpFile IS Not Null
        Begin
          Set @sql = yMaint.MakeBackupCmd( @name + '_' + @DbNameSuffixForMaintenance, 'L', @lastLogBkpFile, 0, Null)
          exec(@sql)        
        End               
      
        If @PathOfBackupBeforeMaintenance <> ''
        Begin
          Set @sql = 'EXECUTE [YourSQLDba].[Maint].[SaveDbCopyOnly] @dbname = "<db>_<suffix>",@PathAndFilename="<backuppath>\<db>_<suffix>.Bak"'
          
          Set @sql = replace(@sql, '<db>', @name)
          Set @sql = replace(@sql, '<suffix>', @DbNameSuffixForMaintenance)
          Set @sql = replace(@sql, '<backuppath>', @PathOfBackupBeforeMaintenance)    
          Set @sql = replace(@sql, '"', '''')
          
          exec(@sql)        

        End  
      
      End Try
      Begin Catch
        Set @msgErr = @name + '_' + @DbNameSuffixForMaintenance + '> ' + ERROR_MESSAGE()
        Raiserror (N'%s', 11, 1, @msgErr)
      End Catch
      
    End
        
    
    -- If specified with the parameter @SetRecoveryModeToSimple, set the 
    -- recovery model to simple during the maintenance
    if @SetRecoveryModeToSimple = 1
    begin
        Set @sql = 
    '   
    if DATABASEPROPERTYEX ("<db>_<suffix>", "recovery") <> "SIMPLE" 
	     Alter database [<db>_<suffix>] Set RECOVERY SIMPLE WITH NO_WAIT	   
    '
      Set @sql = replace(@sql, '<db>', @name)
      Set @sql = replace(@sql, '<suffix>', @DbNameSuffixForMaintenance)
      Set @sql = replace(@sql, '"', '''')
      
      Begin Try
        --print @sql
        exec(@sql)
        
        Print @name + '_' + @DbNameSuffixForMaintenance + ' is in SIMPLE recovery model'
      End Try
      Begin Catch
        Set @msgErr = @name + '_' + @DbNameSuffixForMaintenance + '> ' + ERROR_MESSAGE()
        Raiserror (N'%s', 11, 1, @msgErr)
      End Catch
      
    end


  End

End -- Maint.PrepDbForMaintenanceMode
GO

-- -------------------------------------------------------------------------
-- procedure you need to use ReturnDbToNormalUseFromMaintenanceMode
-- -------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMaint.PrepareRestoreDbToLogMarkCommand'
GO

Create Procedure yMaint.PrepareRestoreDbToLogMarkCommand 
  @DbName nVARCHAR(max) 
, @FullBkpFile nvarchar(512)
, @LogMarkName  nvarchar(32)
, @SqlCmd nvarchar(max) output
As
Begin
  Declare @sql nvarchar(max)
  Declare @RestoreLog nvarchar(max)
  Declare @position smallint
  Declare @LogBkpFile nvarchar(512)
  Declare @MediaSetId int

  Set @SqlCmd = 
  '
  Restore Database [<db>] From Disk = "<FullBackupFile>" With NoRecovery ,stats=1, replace
  <LogRestore>
  Restore Log [<db>] With Recovery
  '

  -- Find all log backups associated with the full backup    
  Set @MediaSetId = 0
  While 1=1
  Begin
  
    Select Top 1 @MediaSetId= bm.media_set_id,  @LogBkpFile = bm.physical_device_name
    From
      (
      Select bs.database_name, bs.first_lsn
      From 
        YourSQLDba.Maint.JobLastBkpLocations lb
        join
        msdb.dbo.backupset bs
        on   bs.database_name = lb.dbName collate database_default
         And RIGHT( bs.name, Len(lb.lastFullBkpFile)) = lb.lastFullBkpFile collate database_default
      Where lb.lastFullBkpFile = @FullBkpFile
        And (bs.name like 'YourSqlDba%' or bs.name like 'SaveDbOnNewFileSet%')
        And bs.type = 'D'
      ) X
      
      Join
      msdb.dbo.backupset bs
      On   bs.database_name = X.database_name
       And bs.database_backup_lsn = X.first_lsn
       
      Join
      msdb.dbo.backupmediafamily bm
      On  bm.media_set_id = bs.media_set_id
      
    Where bs.type = 'L' 
      And bm.media_set_id > @MediaSetId 
      
    If @@ROWCOUNT = 0
      Break
      
    Exec yMaint.CollectBackupHeaderInfoFromBackupFile @LogBkpFile
        
    -- Restore all log backup until the log mark  
    Set @position = 0
    while 1=1
    Begin
    
      Select Top 1 @position = Position
      From Maint.TemporaryBackupHeaderInfo 
      Where Spid = @@spid 
        And BackupType = 2
        And Position > @position
      Order by Position
      
      If @@rowcount= 0
        break
        
      Set @RestoreLog = 'Restore Log [<db>] From Disk="<LogBackupFile>" With FILE=<Position>, NoRecovery, STOPATMARK="<StopMark>"'  
      Set @RestoreLog = Replace(@RestoreLog, '<Position>', Convert(nvarchar(255), @position))
      
      Set @SqlCmd = replace(@SqlCmd, '<LogRestore>', @RestoreLog +  Char(13) + Char(10) + '<LogRestore>' )  
      Set @SqlCmd = replace(@SqlCmd, '<LogBackupFile>', @LogBkpFile)
        
    End
  
  End  
  
  Set @SqlCmd = replace(@SqlCmd, '<LogRestore>', '')
  Set @SqlCmd = replace(@SqlCmd, '<db>', @DbName)
  Set @SqlCmd = replace(@SqlCmd, '<StopMark>', @LogMarkName)
  Set @SqlCmd = replace(@SqlCmd, '<FullBackupFile>', @FullBkpFile)
  Set @SqlCmd = replace(@SqlCmd, '"', '''')

End -- yMaint.PrepareRestoreDbToLogMarkCommand
GO

-- -------------------------------------------------------------------------
-- Restore databases to their state before maintenance process is started.
-- They are still in maintenance mode and original backup remains available
-- for other maintenance attempts.
-- Requires that PrepDbForMaintenanceMode was used in the way necessary to 
-- generate a backup (i.e. by supplying a valid backup path, not empty string).
-- Your must supply in @bdlist each database you want to restore.
-- Can be used to abort maintenance attempt and report it later, but after this 
-- procedure you need to use ReturnDbToNormalUseFromMaintenanceMode
-- -------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.RestoreDbAtStartOfMaintenanceMode'
GO

Create Procedure Maint.RestoreDbAtStartOfMaintenanceMode 
  @DbList nVARCHAR(max) 
, @DbNameSuffixForMaintenance nvarchar(128) 
, @PathOfBackupBeforeMaintenance nvarchar(512) = NULL
as
Begin 
 
  Set nocount on    
  
  Set @DbNameSuffixForMaintenance = isnull(@DbNameSuffixForMaintenance, '')
  Set @PathOfBackupBeforeMaintenance = ISNULL (@PathOfBackupBeforeMaintenance, '')
  
  If Right(@PathOfBackupBeforeMaintenance ,1) = '\'
    Set @PathOfBackupBeforeMaintenance=
        Left(@PathOfBackupBeforeMaintenance, len(@PathOfBackupBeforeMaintenance) - 1)
    
  Select 
    d.name collate database_default as Dbname
  , lastLogBkpFile
  , lastFullBkpFile
  , row_number() over (order by line) seq 
  into #Tmp
  From 
    yUtl.SplitParamInRows (@dbList) AS X
    
    join 
    master.sys.databases d
    on d.name = x.line + '_' + @DbNameSuffixForMaintenance collate database_default
  
    left join
    Maint.JobLastBkpLocations bl
    on bl.dbName = x.line collate database_default
  
  Declare @name sysname
  Declare @sql nvarchar(max)
  Declare @seq int
  Declare @lastLogBkpFile nvarchar(512)
  Declare @lastFullBkpFile nvarchar(512)
  Declare @msgErr nvarchar(max)
  
  Set @seq = 0

  While (1=1)
  Begin

    Select top 1 @name = DbName
               , @seq = seq
               , @lastLogBkpFile = lastLogBkpFile
               , @lastFullBkpFile = lastFullBkpFile
    from #Tmp Where seq > @seq Order by seq

    If @@rowcount = 0 break

    If @PathOfBackupBeforeMaintenance = '' And @lastLogBkpFile Is Null
    Begin 
      Raiserror (N'No backup for database %s', 11, 1, @name)
      --Print 'No backup for database «' + @name  + '»'
    End
    Else
    Begin
      
      -- If a backup file is specified we restore form the Full backup in this path.
      -- Else we Restore the last Full Backup and all the log Backup until the start of the maintenance mode      
      Begin Try

        If @PathOfBackupBeforeMaintenance <> ''
        Begin
          -- Kill all connection Before launching the RESTORE Command
          Set @sql = '
          ALTER DATABASE [<db>] SET OFFLINE WITH ROLLBACK IMMEDIATE
          ALTER DATABASE [<db>] SET ONLINE
          ALTER DATABASE [<db>] SET MULTI_USER WITH ROLLBACK IMMEDIATE
          Restore Database [<db>] From Disk = "<backuppath>\<db>.Bak" With stats=1, replace
          '
        
          Set @sql = replace(@sql, '<db>', @name)
          Set @sql = replace(@sql, '<backuppath>', @PathOfBackupBeforeMaintenance)    
          Set @sql = replace(@sql, '"', '''')
          Set @sql = yExecNLog.Unindent_TSQL( @sql )
          --print @sql
          exec(@sql)
        End
        Else
        Begin
          Exec yMaint.PrepareRestoreDbToLogMarkCommand 
                                        @DbName=@name
                                      , @FullBkpFile=@lastFullBkpFile
                                      , @LogMarkName='PrepDbForMaintenanceMode'
                                      , @SqlCmd=@sql out

          -- Kill all connection Before launching the RESTORE Command
          Set @sql = '
          ALTER DATABASE [<db>] SET OFFLINE WITH ROLLBACK IMMEDIATE
          ALTER DATABASE [<db>] SET ONLINE
          ALTER DATABASE [<db>] SET MULTI_USER WITH ROLLBACK IMMEDIATE
          '+@Sql
                 
          Set @sql = replace(@sql, '<db>', @name)
          Set @sql = replace(@sql, '<backuppath>', @PathOfBackupBeforeMaintenance)    
          Set @sql = replace(@sql, '"', '''')
          Set @sql = yExecNLog.Unindent_TSQL( @sql )
          --print @sql
          exec(@sql)

        End
        
        Print @name + ' restored '
      End Try
      Begin Catch
        Set @msgErr = @name + '> ' + ERROR_MESSAGE()
        Raiserror (N'%s', 11, 1, @msgErr)
      End Catch
              
    End    
     
  End
  
  Drop Table #Tmp

End -- Maint.RestoreDbAtStartOfMaintenanceMode
GO
-- --------------------------------------------------------------------------
-- Restore databases names to their original value and original recovery mode.
-- Database list need to be supplied, and suffix use to rename the database.
-- If the database is part of regular YourSqlDba full backups, then a new
-- file backup set (a new total backup and a new log backup are directed to 
-- a new file set) so you keep backup before maintenance process.
-- Backup files generated by PrepDbForMaintenanceMode at start of maintenance process 
-- are also left there and you must perform a manual cleanup of them.
-- -------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Maint.ReturnDbToNormalUseFromMaintenanceMode'
GO

Create Procedure Maint.ReturnDbToNormalUseFromMaintenanceMode 
  @DbList nVARCHAR(max) = '' -- @DbList : See comments later for further explanations
, @DbNameSuffixForMaintenance nvarchar(128)
as
Begin 

  Set nocount on

  Set @DbNameSuffixForMaintenance= isnull(@DbNameSuffixForMaintenance, '')

  Select d.name as Dbname, row_number() over (order by line) seq 
  into #Tmp
  From 
    yUtl.SplitParamInRows (@dbList) AS X
    join 
    master.sys.databases d
    on d.name collate database_default = x.line  + '_' + @DbNameSuffixForMaintenance

  Declare @dbOrig sysname
  Declare @sql nvarchar(max)
  Declare @seq int
  Declare @msgErr nvarchar(max)
  Declare @DbAndSuffix sysname
  Declare @recovery_model_saved Int
  Declare @recovery_model sysname 
 
  Set @seq = 0

  Select * from #tmp

  Begin Try

  While (1=1)
  Begin
      
    Select top 1 @DbAndSuffix = DbName, @seq = seq 
    from #Tmp Where seq > @seq Order by seq

    If @@rowcount = 0 break

    -- remove the suffix from the name
    Set @dbOrig = STUFF(  @DbAndSuffix
                      , len(@DbAndSuffix)-Len(@DbNameSuffixForMaintenance)
                      , Len(@DbNameSuffixForMaintenance)+1, ''
                      )

    Set @sql = 
    '
    Use [<DbAndSuffix>];
    Set @recovery_model_saved = 
    convert(int, objectpropertyex(object_id("dbo.RecoveryModelBeforePrepDbForMaintenanceMode"), "isUserTable"))
    '
    Set @sql = replace(@sql, '<DbAndSuffix>', @DbAndSuffix)
    Set @sql = replace(@sql, '"', '''')
    Exec Sp_ExecuteSql @Sql, N'@recovery_model_saved int output', @recovery_model_saved Output

    If @Recovery_model_saved = 1
    Begin
      Set @sql = 'select @recovery_model = recovery_model_desc From [<DbAndSuffix>].dbo.RecoveryModelBeforePrepDbForMaintenanceMode'
      Set @sql = replace(@sql, '<DbAndSuffix>', @DbAndSuffix)
      Exec Sp_ExecuteSql @Sql, N'@recovery_model sysname output', @recovery_model Output
   
      Set @sql = 
      '
      If Db_name() <> "Master"  Use Master;
	     Alter database [<DbAndSuffix>] SET OFFLINE WITH ROLLBACK IMMEDIATE
	     Alter database [<DbAndSuffix>] SET ONLINE
      Alter Database [<DbAndSuffix>] Set RECOVERY <recovery_model>
      Drop Table [<DbAndSuffix>].dbo.RecoveryModelBeforePrepDbForMaintenanceMode
      '
      Set @sql = replace(@sql, '<DbAndSuffix>', @DbAndSuffix)
      Set @sql = replace(@sql, '<recovery_model>', @recovery_model)
      Set @sql = replace(@sql, '"', '''')
      Exec (@sql)
    End

    Set @sql = 
    '
    If Db_name() <> "Master"  Use Master;
	   Alter database [<DbAndSuffix>] SET OFFLINE WITH ROLLBACK IMMEDIATE
	   Alter database [<DbAndSuffix>] SET ONLINE
	   Alter database [<DbAndSuffix>] MODIFY NAME = [<db>]
	   Alter database [<db>] Set MULTI_USER With Rollback  Immediate
    '
    Set @sql = replace(@sql, '<DbAndSuffix>', @DbAndSuffix)
    Set @sql = replace(@sql, '<Db>', @dbOrig)
    Set @sql = replace(@sql, '"', '''')
    Exec (@sql)
 	   
    If Exists(Select *
              From [YourSQLDba].[Maint].[JobLastBkpLocations]
              Where dbName=@DbOrig
                And lastFullBkpFile Is Not Null)
    Begin
   	  Exec [YourSQLDba].[Maint].[SaveDbOnNewFileSet] @DbName=@DbOrig
      Update [YourSQLDba].[Maint].[JobLastBkpLocations] Set keepTrace=0 Where dbName=@DbOrig
	   End

    Print @dbOrig + ' returned to normal use'
  End

  End Try
  Begin Catch
    Set @msgErr = @DbOrig + '> ' + ERROR_MESSAGE()
    Raiserror (N'%s', 11, 1, @msgErr)
  End Catch


End -- Maint.ReturnDbToNormalUseFromMaintenanceMode
GO


-- required since all objects are qualified by YourSqlDba

  declare @job_id UniqueIdentifier
  declare @step_id int
  declare @tmp table (job_id UniqueIdentifier, step_id int)
  Insert into @tmp 
  Select job_id, step_id 
  from msdb.dbo.sysjobsteps
  Where step_name like '%YourSqlDba%'
    And database_name not like '%YourSqlDba%'

  -- for an unknow reason a direct update of database_name on this column doesn't work.
  -- so we look using sp_update_jobstep
  while (1=1) 
  Begin
    Select top 1 @job_id = job_id, @step_id = step_id 
    from @tmp 
    If @@rowcount = 0 break
    
    EXEC msdb.dbo.sp_update_jobstep 
      @job_id = @job_id,
      @step_id = @step_id,
		    @database_name = N'YourSQLDba'

    Delete from @tmp where job_id = @job_id And step_id = @step_id 
  End  
go


-- ---------------------------------------------------------------------------------------
-- Proc to create database export
-- ---------------------------------------------------------------------------------------
If objectpropertyEx(object_id('yExport.CreateExportDatabase'), 'isProcedure') = 1 
  Drop procedure yExport.CreateExportDatabase
GO
create procedure yExport.CreateExportDatabase 
  @dbName sysname 
, @collation sysname = NULL
, @stopOnError Int = 1  
, @jobNo int
as
Begin 
  set nocount on
  declare @sql nvarchar(max); set @sql = ''
  declare @sqlM nvarchar(max); set @sqlM = ''
  declare @minSizeData Int
  declare @minSizeLog Int
  declare @rc int
  Declare @fgId Int
  Declare @type_desc sysname
  Declare @fSpec nvarchar(max) 
  Declare @fgn sysname  


  Declare @Name sysname
  Declare @PhysicalName nvarchar(512)
  Declare @DataSpaceid int
  Declare @fileGroupName sysname
  Declare @fileGroupNameAv sysname
  Declare @FileId int
  Declare @Size nvarchar(40)
  Declare @maxSize nvarchar(40)
  Declare @maxSizeUnit nvarchar(40)
  Declare @Growth nvarchar(40)
  Declare @GrowthMode nvarchar(2)
  Declare @context nvarchar(200)
  Declare @Info nvarchar(max)
  Declare @err nvarchar(max)

  If databasepropertyex(@dbName+'_Export','status') IS NOT NULL 
  Begin
    Set @err = 'Error - Database "'
                  + @dbName
                  + '_Export" must be removed first as it is the destination name of exported database "'
                  + @dbName 
                  + '"'
    Exec yExecNLog.LogAndOrExec 
      @context = 'yExport.CreateExportDatabase' 
    , @Info = 'Database for export must not be there' 
    , @err = @err
    , @jobNo = @jobNo
    , @raiseError = @stopOnError
    return(1)
  End
  
  Set @sql = 
  '
  CREATE DATABASE [<DbName>_Export]
  ON 
    <FSpecData>
  Log On 
    <fSpecLog>
  Collate <Collate>  
  '
  Set @sql = REPLACE(@Sql, '<DbName>', @dbName)
  If @collation Is Null
    Set @sql = REPLACE(@Sql, '<collate>', convert(sysname, DatabasepropertyEx(@dbName, 'Collation')))
  else
    Set @sql = REPLACE(@Sql, '<collate>', @collation)

  Set @fileId = 0
  Set @DataSpaceid = 0
  Set @fileGroupNameAv = ''
  
  Set @fSpec = 
  '
  <Fgroup>
  <fSpec>
  '

  While (1=1)
  begin
    Set @sqlM = -- fichiers data, du groupe primaire en premier, puis des autres
    '
    use [<DbName>]
    Select Top 1 
      @FileId = file_id
    , @dataSpaceId = data_space_id  
    , @fileGroupName = Filegroup_Name (data_space_id)
    , @Name = name
    , @PhysicalName = physical_name
    , @Size = str(Case when size / 10 < 1024*200 Then 1024*200 else (size / 10) * 8 End)+"KB" -- translate to KB actually 8Kb pages
    , @MaxSize = Case 
                   When max_Size <= 0 Then "Unlimited" 
                   When max_Size = 268435456 Then "2"
                   Else STR(max_size * 8,10) End
    , @maxSizeUnit = Case 
                       when max_Size = -1 Then "" 
                       when max_Size = 268435456 Then "TB" 
                       Else "KB" 
                     End
    , @Growth = Case When is_percent_growth = 1 then Str(Growth,10) Else 1024*200 End -- translate to KB 8KB pages
    , @GrowthMode = Case When is_percent_growth = 1 Then "%" Else "KB" End 
    From sys.database_files d
    Where 
      data_space_id > 0 And -- no log files
      Str(data_space_id)+Str(File_id) > Str(@dataSpaceId)+Str(@Fileid) And
      (convert(nvarchar, serverproperty("productversion")) not like "9.%" Or type_desc <> "FULLTEXT")
      -- exclude unusual file setup made when a sql2005 database with full text is restored to a version above
       And not exists(select * from sys.fulltext_Catalogs F where F.name = replace(d.name, "ftrow_", ""))
    Order by data_space_id, File_id
    '
    Set @sqlM = replace (@sqlM, '<dbname>', @dbName)
    Set @sqlM = replace (@sqlM, '"', '''')
    Exec sp_executeSql 
      @SqlM
    ,N' @FileId int output
      , @dataSpaceId int output
      , @fileGroupName sysname output
      , @Name sysname Output
      , @PhysicalName nvarchar(512) Output
      , @Size nvarchar(40) Output
      , @MaxSize nvarchar(40) Output
      , @maxSizeUnit nvarchar(40) Output
      , @Growth nvarchar(40) Output
      , @GrowthMode nvarchar(2) Output
      '
    , @FileId = @FileId Output
    , @dataSpaceId = @dataSpaceId Output
    , @fileGroupName = @fileGroupName Output
    , @Name = @name Output
    , @PhysicalName = @PhysicalName output
    , @Size = @Size Output
    , @maxSize = @maxSize Output
    , @maxSizeUnit = @maxSizeUnit Output
    , @Growth = @Growth Output
    , @GrowthMode = @GrowthMode Output
    
    if @@ROWCOUNT = 0 
      Break
      
    If @FileGroupNameAv <> @fileGroupName 
    Begin
      Set @fSpec = REPLACE(  @fSpec, '<Fgroup>'
                           , Case -- avoid use of primary keyword and add a comma if more that one file
                               When @fileGroupName = 'Primary' 
                               Then ''
                               Else 'FILEGROUP ' +@FileGroupName 
                           End)
      Set @FileGroupNameAv = @fileGroupName 
    End  
    Else  
      Set @fSpec = REPLACE(@fSpec, ', <Fgroup>', ', ')
      
    Set @fSpec = REPLACE(@fSpec, '<FSpec>', 
   '
    (
      NAME = <LogicalFileName>
    , FILENAME = "<PhysicalFileName>"
    , SIZE = <size>
    , MAXSIZE = <max_size>
    , FILEGROWTH = <growth>
    )
  , <FGroup>
    <fSpec>'
    )   

    
    Set @fSpec = REPLACE(@fSpec, '<LogicalFileName>', Replace (@name, @dbName, @dbName+'_Export'))
    Set @fSpec = REPLACE(@fSpec, '<PhysicalFileName>',  Replace (@physicalName, @dbName, @dbName+'_Export') )
    Set @fSpec = REPLACE(@fSpec, '<Size>', @Size)
    Set @fSpec = REPLACE(@fSpec, '<max_Size>', @maxSize + @maxSizeUnit)
    Set @fSpec = REPLACE(@fSpec, '<growth>', @Growth + @growthMode)

  End
  Set @fSpec = REPLACE(@fSpec, ', <FGroup>', '') -- remove remaining tag
  Set @fSpec = REPLACE(@fSpec, '<FSpec>', '') -- remove remaining tag
  
  Set @Sql = REPLACE (@sql, '<FSpecData>', @fSpec) -- insert it into create database stmt
    

  Set @fileId = 0
  Set @fSpec = 
  '
  <FSpec>
  '
      
  While (1=1)
  begin
    Set @sqlM = -- fichiers data, du groupe primaire en premier, puis des autres
    '
    use [<DbName>]
    Select Top 1 
      @FileId = file_id
    , @dataSpaceId = data_space_id  
    , @fileGroupName = Filegroup_Name (data_space_id)
    , @Name = name
    , @PhysicalName = physical_name
    , @Size = str(Case when size / 10 < 1024*200 Then 1024*200 else (size / 10) * 8 End)+"KB" -- translate to KB actually 8Kb pages
    , @MaxSize = Case 
                   When max_Size <= 0 Then "Unlimited" 
                   When max_Size = 268435456 Then "2"
                   Else STR(max_size * 8,10) End
    , @maxSizeUnit = Case 
                       when max_Size = -1 Then "" 
                       when max_Size = 268435456 Then "TB" 
                       Else "KB" 
                     End
    , @Growth = Case When is_percent_growth = 1 then Str(Growth,10) Else 1024*200 End -- translate to KB 8KB pages
    , @GrowthMode = Case When is_percent_growth = 1 Then "%" Else "KB" End 
    From sys.database_files
    Where 
      data_space_id = 0 And -- log files
      Str(File_id) > Str(@Fileid)
    Order by File_id
    '
    Set @sqlM = replace (@sqlM, '<dbname>', @dbName)
    Set @sqlM = replace (@sqlM, '"', '''')
    Exec sp_executeSql 
      @SqlM
    ,N' @FileId int output
      , @dataSpaceId int output
      , @fileGroupName sysname output
      , @Name sysname Output
      , @PhysicalName nvarchar(512) Output
      , @Size nvarchar(40) Output
      , @MaxSize nvarchar(40) Output
      , @maxSizeUnit nvarchar(40) Output
      , @Growth nvarchar(40) Output
      , @GrowthMode nvarchar(2) Output
      '
    , @FileId = @FileId Output
    , @dataSpaceId = @dataSpaceId Output
    , @fileGroupName = @fileGroupName Output
    , @Name = @name Output
    , @PhysicalName = @PhysicalName output
    , @Size = @Size Output
    , @maxSize = @maxSize Output
    , @maxSizeUnit = @maxSizeUnit Output
    , @Growth = @Growth Output
    , @GrowthMode = @GrowthMode Output
    
    if @@ROWCOUNT = 0 
      Break
      
    Set @fSpec = REPLACE(@fSpec, '<FSpec>', 
    '(
      NAME = <LogicalFileName> 
    , FILENAME = "<PhysicalFileName>"
    , SIZE = <size>
    , MAXSIZE = <max_size>
    , FILEGROWTH = <growth>
    )
    , <FSpec>')   

    Set @fSpec = REPLACE(@fSpec, '<LogicalFileName>', Replace (@name, @dbName, @dbName+'_Export'))
    Set @fSpec = REPLACE(@fSpec, '<PhysicalFileName>',  Replace (@physicalName, @dbName, @dbName+'_Export'))
    Set @fSpec = REPLACE(@fSpec, '<Size>', @size)
    Set @fSpec = REPLACE(@fSpec, '<max_Size>', @maxSize+@maxSizeUnit)
    Set @fSpec = REPLACE(@fSpec, '<growth>', @Growth+@GrowthMode)

  End
  Set @fSpec = REPLACE(@fSpec, ', <FSpec>', '') -- remove remaining tag
  Set @Sql = REPLACE (@sql, '<FSpecLog>', @fSpec) -- put it into create database
  
  Set @sql = replace(@sql, '"', '''')

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @jobNo
  , @context = 'yExport.CreateExportDatabase'
  , @Info = 'Running create database for database export'  
  , @sql = @sql
  , @raiseError = @stopOnError

End -- yExport.CreateExportDatabase
GO
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
   
if objectpropertyEx(object_id('yExport.ExportData'), 'isProcedure') = 1 
  Drop Procedure yExport.ExportData
GO
Create Procedure yExport.ExportData
  @dbName sysname
, @stopOnError Int = 1  
, @jobNo Int
as
Begin
  Set nocount on

  declare @sql nvarchar(max) -- 

  Declare @nbRow int

  declare @rc int
  declare @Ks sysname -- schéma de foreign key 
  declare @USn sysname -- schéma de clé primaire référencée par foreign key 
  declare @Kn sysname -- nom de foreign key 
  declare @Sn sysname -- nom de schema d'index ou de table
  declare @Tn sysname -- nom de table
  declare @UTn sysname -- nom de table de clé primaire référencée par foreign key 
  declare @mn sysname -- module name
  Declare @seqFk Int
  Declare @cn sysname -- nom de colonne
  Declare @iden int -- clause identity
  Declare @defIden sysname -- définition de la clause identity
  Declare @fgDef sysname -- définition du filegroup de table pour les LOB
  Declare @fgDat sysname -- définition de filegroup de table pour les rangées
  Declare @fgLob sysname -- définition du filegroup de table pour les LOB
  Declare @fgIdx sysname -- définition du filegroup de l'index
  Declare @is_computed int   -- si colonne calculée
  Declare @computedColDef nvarchar(max)   -- si colonne calculée, sa définition 
  declare @Ucn sysname -- nom de colonne de clé primaire référencée par foreign key 
  declare @In sysname -- nom d'index ou de clé primaire ou de contrainte unique
  declare @Pk Int     -- indicateur clé primaire
  declare @typDesc Sysname -- type d'index clustered, nonclustered
  declare @dcn sysname -- nom de contrainte default
  declare @DefName sysname -- définition du default
  declare @typ sysname -- type d'une colonne ou type d'un objet selon le bout de code local
  declare @nouvTyp sysname -- nouveau type d'une colonne dans cas de char, varchar, text, image
  declare @lc nvarchar(8) -- définition de longueur d'une colonne
  declare @nullSpec nvarchar(8) -- spéc. NULL, NOT NULL
  Declare @seq  Int -- sequence de traitement dans les tables
  Declare @seqT Int -- sequence des tables
  Declare @seqC Int -- séquence des colonnes
  Declare @Def nvarchar(max) -- définition de l'expression qui donne le defaut d'une colonne 
  Declare @Cols nvarchar(max)  -- liste des colonnes 
  Declare @ligCols nvarchar(max)  -- liste des colonnes sur une même ligne
  Declare @ColsSelect nvarchar(max)  -- liste des colonnes d'une table pour select into, ou colonne d'un index selon usage
  Declare @colsCreateTable nvarchar(max)  -- liste des colonnes d'une table pour alter constraint
  Declare @colsInsertInto nvarchar(max)  -- liste alter des colonnes d'une table pour alter null not null
  Declare @uCols nvarchar(max)  -- liste des colonnes de la clé primaire référencée par la clé unique
  Declare @ColIdxChar Int 

  Declare @schemaAlt int -- says that a view nust be used to pump the data

  Declare @ko int -- ordre des colonnes dans la clé
  Declare @iUniq int -- index unique ou pas
  Declare @iUniqC Int -- contrainte unique mais pas nécessairement primary key
  Declare @FKOnClause NVARCHAR(255)
  Declare @is_not_trusted int -- indique si la contrainte de foreigh key est activée

  Declare @Info nvarchar(max)

  Declare @seqIx Int
  Declare @BigLig nvarchar(max)
  Declare @IndexOnView int
  
  Declare @Created int
  Declare @FunctionCreated int
  Declare @TableCreated int
  Declare @Anull int
  Declare @qIden int
  declare @err nvarchar(max)


  Begin try

  Create table #Schemas
  (
  Sn  sysname Not NULL  primary key clustered 
  )

-- table des définitions des types 
  create table #UserDefTypes
  (
    seq  int primary key clustered
  , sn sysname NOT NULL         -- nom schema
  , un sysname NOT NULL         -- nom user type
  , typ sysname NOT NULL        -- type
  , lc nvarchar(10) NULL        -- longueur facultative
  , nullspec nvarchar(10) NULL  -- ajouter null ou not null
  )

-- table des définitions de foreigh key
--    if object_id('tempdb..#RefConstraints') is not null drop table #RefConstraints
  create table #RefConstraints 
  (
    seq  int primary key clustered
  , Sn   sysname not NULL
  , Tn   sysname not NULL
  , Kn   sysname not NULL
  , USn  sysname not NULL
  , UTn  Sysname Not NULL
  , UKn  sysname not NULL
  , RefObjId Int not NULL
  , KeyId Int not NULL
  , MATCH_OPTION sysname not NULL
  , UPDATE_RULE sysname not NULL 
  , DELETE_RULE sysname not NULL
  , Is_not_trusted int not null
  )

-- liste des colonnes impliquées dans contraintes d'intégrité référentielle des foreigh key
--  if object_id('tempdb..#ColsRefConstraints') is not null drop table #ColsRefConstraints
  create table #ColsRefConstraints 
  (
    Sn     sysname NOT NULL
  , Tn     sysname NOT NULL
  , Kn     sysname NOT NULL
  , ordCol Int     NOT NULL
  , cn     sysname NOT NULL 
  , USn    sysname NOT NULL
  , UKn    sysname NOT NULL
  , UTn    sysname NOT NULL
  , Ucn    sysname NOT NULL
  )
  Create unique clustered index iKC on #ColsRefConstraints (Sn, Tn, Kn, OrdCol)

-- liste des tables d'une BD
--  if object_id('tempdb..#TablesToExport') is not null drop table #TablesToExport
  create table #TablesToExport
  (
    seq int primary key clustered 
  , sn sysname  NOT NULL -- nom schema
  , tn sysname  NOT NULL -- nom table 
  , Id int      NOT NULL -- id de la table
  , Iden int    NOT NULL -- a un identity
  , fgLob sysname  NOT NULL Default '' -- filegroup pour LOB
  , fgDat sysname  NOT NULL Default '' -- filegroup du Data
  , fgDef  sysname NOT NULL Default '' -- default filegroup amoung filegroups
  )

  -- ---------------------------------------------------------------------------------------------------
  -- table qui conserve les instructions pour rebâtir les statistiques d'origine crées par auto-stats
  -- ---------------------------------------------------------------------------------------------------
-- informations pour regénérer des statistiques sur colonnes des statistiques auto-générées d'une BD
--  if object_id('tempdb..#Stats') is not null drop table #Stats
  create table #Stats
  (
    seq int primary key clustered 
  , sn sysname  NOT NULL -- nom schema
  , tn sysname  NOT NULL -- nom table 
  , cn sysname  NOT NULL -- nom colonne
  )

-- liste des colonnes des tables
--    if object_id('tempdb..#ColsTablesAMigr') is not null drop table #ColsTablesAMigr
  create table #ColsTablesAMigr 
  (
    sn sysname NOT NULL         -- nom schema
  , tn sysname NOT NULL         -- nom table 
  , cn sysname NOT NULL         -- nom colonne
  , typ sysname NOT NULL        -- type
  , defIden sysname NOT NULL  -- si elle a une définition identity
  , lc sysname NOT NULL     -- nouvelle longueur comme dans définition de table
  , DefName sysname NOT NULL     -- nom du défaut s'il existe
  , Def nvarchar(max) NOT NULL  -- expression qui le représente s'il existe
  , nullSpec sysname NOT NULL    -- signale si la colonne peut être mise à null
  , is_computed int not null     -- signale si c'est une colonne calculée
  , computedColDef nvarchar(max) NULL -- expression de colonne calculée si c'est le cas
  , OrdCol int  NOT NULL        -- position relative croissante des colonnes, trous possibles dans séquence
  )
  Create unique clustered index iTC on #ColsTablesAMigr (Sn, Tn, OrdCol)

-- liste des index des tables
--    if object_id('tempdb..#Indexes') is not null drop table #Indexes
  Create table #Indexes
  (
    sn sysname NOT NULL
  , tn sysname NOT NULL 
  , IdxName sysname NOT NULL
  , type_desc sysname NOT NULL
  , is_unique int NOT NULL
  , is_primary_key int NOT NULL
  , is_unique_constraint int NOT NULL
  , object_id Int NOT NULL
  , index_id Int NOT NULL
  , fgIdx sysname  NOT NULL Default ''
  , IndexOnView int null
  )
  Create unique clustered index iIX on #Indexes (Sn, Tn, IdxName)

  -- liste des colonnes des index des tables
  Declare @seqIxc Int
--  if object_id('tempdb..#IndexesCols') is not null drop table #IndexesCols
  Create table #IndexesCols
  (
    sn sysname NOT NULL
  , tn sysname NOT NULL 
  , IdxName sysname NOT NULL
  , cn sysname NOT NULL
  , Seq Int Identity NOT NULL -- pour rendre la clé ci dessous unique, pas uilisée ailleurs
  , Ko int NOT NULL
  , ColIdxChar int not NULL -- pour signaler si type Char ou pas
  )
  Create unique clustered index iIXC on #IndexesCols (sn, tn, IdxName, seq, ko)

  print '==========================================================================================='
  print '--  ['+@dbName+'] Data export '
  print '==========================================================================================='
  
  -- optimiser l'insertion massive, plus tard remettre les options en place
  Set @sql=
  '
  Alter database [<db>_export]
  Set recovery Simple
  '
  Set @sql = replace(@sql, '<db>', @dbName)

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @jobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Put Export Db is simple recovery'
  , @sql = @sql
  , @raiseError = @stopOnError

  -- ---------------------------------------------------------------------------------------------------
  -- generate stmt to rebuild stats
  -- ---------------------------------------------------------------------------------------------------
  Set @sql =
  '
  use [<Db>]
  ;With ColWithStats
  as
  (
  select Distinct 
    Schema_name(OB.schema_id) as sn
  , Ob.name as Tn
  , c.name as Cn
  From
    sys.stats Ixs
    join
    sys.objects OB
    ON OB.object_id = Ixs.Object_id
    Join
    sys.stats_columns Ixc
    ON     Ixc.object_id = Ixs.object_id 
       And Ixc.stats_id = Ixs.stats_id
    join
    sys.columns C
    On     c.object_id = Ixc.object_id
       And c.column_id = Ixc.column_id 
  Where     
    objectpropertyEx(ixs.object_id, "IsUserTable") = 1
    And not exists(Select * from sys.indexes I where I.name = Ixs.name)
    And Schema_name (OB.schema_id) NOT IN ("sys")
    And objectpropertyEx(OB.object_id, "isMsShipped") = 0 -- on veut pas toucher aux objets 
                                                        -- systèmes ex: Dt% 
    And not (ob.name = "sysdiagrams" and Schema_name(OB.schema_id)="dbo")                                                   
  )
  Insert into #Stats (seq, sn, tn, cn)
  Select 
    row_number() over (order by sn, tn, cn) as Seq
  , sn
  , Tn
  , Cn
  From
    ColWithStats
  '
  set @sql = replace (@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @jobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording info to rebuild original stats'
  , @sql = @sql
  , @raiseError = @stopOnError

  -- ---------------------------------------------------------------------------------------------------
  -- List existing schema to recreate them
  -- ---------------------------------------------------------------------------------------------------
  Set @sql = 
  '
  Use [<Db>]
  truncate table #Schemas 
  Insert into #Schemas (sn)
  select name as Sn
  from 
    (select distinct schema_id from sys.objects) as Ob
    join 
    sys.schemas S on S.schema_id = Ob.schema_id
  where name not in ("dbo", "sys")
  '
  set @sql = replace (@sql, '<db>', @dbName)
  set @sql = replace (@sql, '<svrCollation>', convert(sysname, Serverproperty('Collation')))
  Set @sql = replace(@sql, '"', '''')

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @jobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording info to rebuild original schema'
  , @sql = @sql
  , @raiseError = @stopOnError

  -- ---------------------------------------------------------------------------------------------------
  -- save definitions of foreign key, primary key, index clustered (non primaire), and index
  -- to recreate them after data load
  -- ---------------------------------------------------------------------------------------------------
  Set @sql = 
  '
  Use [<Db>]
  truncate table #RefConstraints
  Insert into #RefConstraints (Seq, Sn, Tn, Kn, USn, UTn, RefObjId, KeyId, UKn, MATCH_OPTION, UPDATE_RULE, DELETE_RULE, is_not_trusted)
  select 
    row_number() Over (Order by TU.constraint_catalog, TU.constraint_schema, TU.Table_name)
  , TU.constraint_schema 
  , TU.Table_name 
  , TU.constraint_name 
  , isnull(rc.UNIQUE_CONSTRAINT_SCHEMA,"") 
  , isnull(object_name(FK.referenced_object_id), "")  
  , FK.referenced_object_id
  , FK.Key_index_id
  , isnull(rc.UNIQUE_CONSTRAINT_NAME,"") 
  , isnull(RC.MATCH_OPTION,"") 
  , isnull(RC.UPDATE_RULE,"") 
  , isnull(RC.DELETE_RULE,"") 
  , fk.is_not_trusted
  from 
    information_schema.constraint_table_usage TU
    Join
    sys.foreign_keys FK 
    On FK.name = TU.Constraint_name
    join
    INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS RC
    on rc.CONSTRAINT_NAME = TU.CONSTRAINT_NAME 
  '
  set @sql = replace (@sql, '<db>', @dbName)
  set @sql = replace (@sql, '<svrCollation>', convert(sysname, Serverproperty('Collation')))
  Set @sql = replace(@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @jobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording referential constrains info to rebuild them'
  , @sql = @sql
  , @raiseError = @stopOnError
  
  -- query that extract relations between foreign key and their columns matching with primary key and their columns
  Set @sql =
  '
  truncate table #ColsRefConstraints
  Insert into #ColsRefConstraints
     (Sn, Tn, Kn, OrdCol, Cn, USn, UKn, UTn, UCn)
  Select 
    K.Sn, K.Tn, K.Kn, cu.Ordinal_position, cu.Column_name
    , ISNULL (S.name, "")  
    , ISNULL (Ix.name, "") 
    , ISNULL (Ob.name, "") 
    , ISNULL (c.name, "") 
  From
    #RefConstraints K 

    JOIN
    [<db>].INFORMATION_SCHEMA.KEY_COLUMN_USAGE CU
    ON CU.CONSTRAINT_SCHEMA = K.Sn Collate <svrCollation> And
       CU.CONSTRAINT_NAME = K.Kn Collate <svrCollation>  

    left JOIN   -- index clé primaire ou index unique référencé (IX.name)
    [<db>].sys.indexes IX
    on Ix.object_id = K.RefObjId
       And Ix.index_id = K.KeyId

    left JOIN  -- table référencé (Ob.name)
    [<Db>].sys.objects Ob
    on ob.Object_Id = K.RefObjId

    left JOIN   -- schema si index unique référencé (S.name)
    [<Db>].sys.schemas S
    on S.Schema_id = Ob.Schema_id

    LEFT JOIN -- id colonnes de la clé primaire ou de l"index unique référencé
    [<Db>].sys.index_columns Ixc
    ON Ixc.object_id = K.refObjId
       And Ixc.index_id = K.KeyId
       And Ixc.key_Ordinal = CU.ordinal_position 

    LEFT JOIN -- colonnes de la clé primaire ou de l"index unique référencé (C.name)
    [<Db>].sys.columns c
    ON c.object_id = Ixc.object_id 
       And c.column_id = Ixc.column_id
  '  
  set @sql = replace (@sql, '<svrCollation>', convert(sysname, Serverproperty('Collation')))
  set @sql = replace (@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @jobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording referential constrains relations between columns '
  , @sql = @sql
  , @raiseError = @stopOnError
  
-- ---------------------------------------------------------------------------------------------------
-- rebuild table one at the time
-- tablelock hint on insert allows minimally logged operation in version above sql2005
-- when table is empty and still a heap
-- ---------------------------------------------------------------------------------------------------
  
  -- make table list
  Set @sql =
  '
  Use [<Db>]
  Truncate table #TablesToExport
  Insert into #TablesToExport(seq, sn, tn, Id, iden, fgLob, fgDat, fgDef)
  Select  
      ROW_NUMBER() OVER (Order by S.name, T.name)
    , S.name  as sn
    , T.name  as tn
    , T.object_id as Id
    , Case When II.object_id is Not NULL Then 1 Else 0 End as Iden
    , Case -- on remplace DATA par PRIMARY car on laisse tomber le fichier DATA
        When T.lob_data_space_id >= 1 AND T.lob_data_space_id <= 2 
        Then "Primary"
        Else isnull(filegroup_name(T.lob_data_space_id), "")
      End As FgLob
    , Case 
        When I.data_space_id <= 2 
        Then "Primary"
        Else isnull(filegroup_name(I.data_space_id), "") 
      End As FgDat
    , (select top 1 name from sys.filegroups where is_default =1) as fgDef
  from 
    sys.tables T
    join 
    sys.indexes I
    on I.object_id = T.object_id And index_id in (0,1)
    join 
    sys.Schemas S
    On S.schema_id = T.schema_id
    left join
    sys.identity_columns II
    On II.object_id = T.object_id 
  Where objectpropertyEx(I.object_id, "isMsShipped") = 0 -- avoid system tables Dt% 
    And not (T.name = "sysdiagrams" And S.name = "dbo") -- special case to handle
  '
  set @sql = replace (@sql, '<svrCollation>', convert(sysname, Serverproperty('Collation')))
  Set @sql = replace(@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording tables to migrate '
  , @sql = @sql
  , @raiseError = @stopOnError


---------------------------------------------------------------------------------------
-- collect useful column info that will allow to inactivate and reactivate 
-- défaults 
---------------------------------------------------------------------------------------
  Set @sql = 
  '
  use [<db>]
  truncate table #ColsTablesAMigr
  ;With TabList
  as
  (
  /*
        (Select 
           "dbo" as sn, name as tn, object_id as id, 0 as iden, *
         from [<Db>].sys.tables
        ) as T
  */      
  Select *
  From #TablesToExport as T      
  )
  , colNamesTypesCharLenPrecScale
  as
  (
  Select 
    object_id 
  , sc.name collate Latin1_General_CI_AI as column_name 
  , st.name collate Latin1_General_CI_AI as data_type 
  , column_id  
  , case 
      when sc.max_length> 1 And type_name(sc.system_type_id) like "N%CHAR"
      then sc.max_length / 2 
      else sc.max_length 
    End  character_maximum_length -- longueur en caractères pas en byte
  , sc.precision as numeric_precision
  , sc.scale as numeric_scale
  From
    sys.columns sc
    left join
    sys.types ST -- ne plus utiliser type_name() en dehors du contexte de Bd
  On ST.user_type_id = Sc.user_type_id      
  )  
  , CompleteBaseInfoOnTable
  as
  (
  Select 
      T.Sn  As Sn
    , T.Tn  As Tn
    , T.Iden As Iden
    , sc.name As Cn
    , Cn.data_type  As Typ
    , Cn.column_id As OrdCol
    , Cn.character_maximum_Length as CharMaxLen
    , convert(nvarchar(30), Cn.character_maximum_Length)  as StrCharMaxLen
    , Cn.numeric_precision
    , Cn.numeric_scale
    , isnull(d.definition,"") As def
    , Sc.is_nullable as is_nullable
    , Sc.is_computed as is_computed
    , Scc.definition as computedColDef
    , Coalesce
      (
         Case 
           When d.name is NULL 
           Then "[DF_"+sn+"_"+tn+"_"+cn.column_name+"]" 
         End
       , Case 
           When M.name is NULL 
           Then "[DF_Bind_"+sn+"_"+tn+"_"+cn.column_name+"]"  
         End
       , ""  
      )  As DefName
    , II.column_id as IdenColumn_id
    , II.Seed_Value as IdenSeed_Value 
    , II.Increment_value as IdenIncrement_Value
  From 
    TabList as T      
    Join
    colNamesTypesCharLenPrecScale as Cn
    On Cn.object_id = T.Id 
    Join
    sys.columns Sc
    On Sc.object_id = T.Id And 
       Sc.name = Cn.column_name 
    left join
    sys.computed_columns scc -- pour obtenir définition de la colonne calculée
    on sc.is_computed = 1 And -- optimiser avant joindre
       scc.object_id = Sc.object_id And
       scc.column_id = sc.column_id
    left join
    sys.objects m 
    on m.object_id = Sc.default_object_id
    left Join -- un seule par table
    sys.identity_columns II
    On T.iden = 1 And -- join pas si pa siden sur table
       II.object_id = Sc.object_id And 
       II.column_id = Sc.column_id
    left Join -- pas nécessairement de défaut
    sys.default_constraints d
    On  d.parent_object_id = T.Id And
        d.parent_column_id = sc.column_id
  )
  Insert into #ColsTablesAMigr (sn, tn, cn, typ, lc, defIden, DefName, def, nullSpec, is_computed, computedColDef, ordCol)
  Select 
      Sn 
    , Tn 
    , Cn as cn
    , Typ as Typ 
    , Case -- définition / susbtitution de la longueur
        When Typ like "%CHAR%" or Typ like "%BINARY%"
        Then Case 
               When StrCharMaxLen = "-1" 
               Then "(Max)" 
               Else "(" + StrCharMaxLen +")"
             End  
        When Typ IN ("Decimal", "Numeric")
        Then "("+
             convert(nvarchar, numeric_precision)+"," +
             convert(nvarchar, numeric_scale)+
             ")"
        Else "" -- pas de longueur spécifiable pour ce type
      End as lc
    , Case -- clause identity à mettre ?
        When IdenColumn_Id is NULL
        Then ""
        Else "Identity ("+convert(varchar(40), IdenSeed_value)+","+convert(varchar(40), IdenIncrement_value)+")" 
      End as DefIden
    , DefName
    , Def
    , Case -- retiennent atribut nullable orginal
        When is_nullable = 0 
        Then "NOT NULL" 
        Else "NULL" 
      End as nullSpec
    , is_computed
    , computedColDef
    , OrdCol -- ordre de la colonne dans la table
  From 
    CompleteBaseInfoOnTable
  '

  set @sql = replace (@sql, '<svrCollation>', convert(sysname, Serverproperty('Collation')))
  Set @sql = replace(@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording column info. of tables to migrate'
  , @sql = @sql
  , @raiseError = @stopOnError

-------------------------------------------------------------
-- info to recreate user defined types
-------------------------------------------------------------
  Set @sql = 
  '
  use [<Db>]
  ;With moreConvientUserTypesNameInfo
  as
  (
  Select 
    Sh.name as Schema_name
  , U.name as Uname
  , S.name as Typ
  , U.max_length as charMaxLen
  , convert(varchar, U.max_length) as StrcharMaxLen
  , U.precision as numeric_precision
  , U.scale as numeric_scale
  , Case When U.is_Nullable = 0 Then "NOT NULL" Else "NULL" End as NullSPec
  From 
    sys.types U
    join 
    sys.schemas SH
    On SH.schema_id = U.Schema_id
    join
    sys.types S
    On S.user_type_id = U.system_type_id
  where U.is_user_defined = 1
  ) 
  Insert into #UserDefTypes
  (   seq -- no seq pour traitement seq
    , sn -- nom schema
    , un -- nom user type
    , typ -- type
    , lc -- longueur facultative
    , nullspec -- ajouter null ou not null
  )
  Select 
    Row_number() Over (Order by Schema_name, Uname) as Seq
  , Schema_name
  , Uname
  , Typ 
  , Case -- définition / susbtitution de la longueur
      When Typ like "%char%" or Typ like "%binary%"
      Then Case 
             When StrCharMaxLen = "-1" 
             Then "(Max)" 
             Else "("+StrCharMaxLen+")"
           End 
      When Typ IN ("Decimal", "Numeric")
      Then "("+
           convert(nvarchar, numeric_precision)+"," +
           convert(nvarchar, numeric_scale)+
           ")"
      Else "" -- pas de longueur spécifiable pour ce type
    End as lc
  , NullSPec
  from 
    moreConvientUserTypesNameInfo
  '
  Set @sql = replace(@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording data type info. of columns of tables to migrate'
  , @sql = @sql
  , @raiseError = @stopOnError

-- interesting trace
---select * from #TablesToExport
---select * from #ColsTablesAMigr

------------------------------
-- keep tables index info
------------------------------
  Set @sql =
  '
  Use [<Db>]
  truncate table #Indexes
  insert into #Indexes
  select 
    T.sn
  , T.tn  
  , Ix.name as IdxName 
  , Ix.type_desc 
  , Ix.is_unique 
  , Ix.is_primary_key 
  , Ix.is_unique_constraint 
  , Ix.Object_id 
  , Ix.Index_id
  , Case 
      When Ix.data_space_id <= 2
      Then "Primary"
      Else isnull(filegroup_name(Ix.data_space_id), "") 
    End As FgDat
  , convert(int, objectpropertyex(object_id, "isView")) as IndexonView
  From
    #TablesToExport T
    join 
    sys.indexes Ix
    ON 
           Ix.object_id = T.Id
       And Ix.is_hypothetical = 0
       And Ix.type_desc NOT IN ("HEAP", "XML") 
  Order By  
    T.Sn, 
    T.Tn, 
    Ix.name
  '
  set @sql = replace (@sql, '<svrCollation>', convert(sysname, Serverproperty('Collation')))
  Set @sql = replace(@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')
  
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording index info.'
  , @sql = @sql
  , @raiseError = @stopOnError
  
  Set @sql =
  '
  Use [<Db>]
  truncate table #IndexesCols
  insert into #IndexesCols (sn, tn, IdxName, cn, ko, ColIdxChar)
  select 
    Ix.Sn, Ix.Tn, Ix.IdxName, 
    c.name as nomCol, 
    ixc.key_ordinal,
    Case When st.name in ("char", "nchar", "varchar", "nvarchar", "sysname", "Text") Then 1 Else 0 End
  From
    #Indexes Ix
    join 
    sys.index_columns Ixc
    ON Ixc.object_id = Ix.object_id 
       And Ixc.index_id = Ix.index_id 
    join
    sys.columns C
    On     c.object_id = Ixc.object_id
       And c.column_id = Ixc.column_id  
    join master.sys.types st 
    On st.system_type_id = C.system_type_id   
  Order by sn, tn, IdxName, ixc.key_ordinal 
  '
  set @sql = replace (@sql, '<svrCollation>', convert(sysname, Serverproperty('Collation')))
  Set @sql = replace(@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')
  
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recording columns'' indexes info.'
  , @sql = @sql
  , @raiseError = @stopOnError
  
  Declare @iType sysname  
  Declare @fk int

  Declare @PremCol int

  -- -----------------------------------------------------------------------------------------------------
  -- create schema
  -- -----------------------------------------------------------------------------------------------------
  Set @sn = ''
  While (1=1) 
  Begin
    Select top 1 @sn = sn -- next schema
    From #Schemas 
    Where sn > @Sn
    Order by sn
    If @@rowcount = 0 Break -- no more exit

    Set @sql =
    '
    use [<db>_export]
    exec("Create Schema [<sn>] authorization dbo")
    '
    Set @sql = replace(@sql, '"', '''')
    Set @sql = replace(@sql, '<db>', @dbName)
    Set @sql = replace(@sql, '<sn>', @sn)

    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportData'
    , @Info = 'Create schema'
    , @sql = @sql
    , @raiseError = @stopOnError
    
  End

  -- -----------------------------------------------------------------------------------------------------
  -- rebuild user datatypes
  -- -----------------------------------------------------------------------------------------------------
  Set @seq = 0
  While (1=1) 
  Begin
    Select top 1 
      @sn = sn 
    , @nouvTyp = un
    , @typ = typ
    , @lc = ISNULL(lc, '')
    , @nullSpec = ISNULL(nullSpec, '')
    , @seq = seq  
    From #UserDefTypes
    Where seq > @seq
    Order by seq
    If @@rowcount = 0 Break -- no more, exit

    Set @sql =
    '
    use [<db>_export]
    exec("Create Type [<sn>].[<nouvTyp>] From <typ> <lc> <nullSpec>")
    '
    Set @sql = replace(@sql, '"', '''')
    Set @sql = replace(@sql, '<db>', @dbName)
    Set @sql = replace(@sql, '<sn>', @sn)
    Set @sql = replace(@sql, '<nouvTyp>', @nouvTyp)
    Set @sql = replace(@sql, '<typ>', @typ)
    Set @sql = replace(@sql, '<lc>', @lc)
    Set @sql = replace(@sql, '<nullspec>', @nullSpec)
    
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportData'
    , @Info = 'Create data types'
    , @sql = @sql
    , @raiseError = @stopOnError
  End



  create  table #defFunc 
  (
    seq int primary key
    , sn sysname
    , ModuleName sysname
    , def nvarchar(max)
    , anull int
    , qIden int
  )
  Set @sql =
  '
  use [<db>]
  Truncate table #defFunc
  Insert into #defFunc
  Select 
    ROW_NUMBER() Over (order by object_name(object_id))
  , schema_name(convert(int, objectpropertyex(object_id, "schemaId"))) as Sn
  , object_name(object_id)
  , definition
  , uses_ansi_nulls as aNull
  , uses_quoted_identifier as qIden
  From 
    Sys.sql_modules 
  Where OBJECTPROPERTYEX (object_id, "IsScalarFunction") = 1
  '
  Set @sql = replace(@sql, '"', '''')
  Set @sql = replace(@sql, '<db>', @dbName)

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Recreate scalar function and/or views that may be recreated'
  , @sql = @sql
  , @raiseError = @stopOnError

  
  While (1=1) -- at least one scalar function view or table is created
  Begin
    -- ---------------------------------------------------------------------------------------------
    -- Recreate scalar udf that can be used as default
    -- try a blind recreate ignoring what can't be created
    -- only do the attempt for schema bound objects
    -- ---------------------------------------------------------------------------------------------
    
    Set @Created = 0 -- flag as if nothing was created for the loop below
    Set @seq = 0
    
    Set @FunctionCreated = 0 -- to know if this pass has created at least a function
    While(1=1)
    Begin
      Select top 1 
        @seq = seq
        , @sn = sn
        , @mn = ModuleName
        , @def = def
        , @ANull = Anull
        , @qIden = qIden
      from #defFunc
      Where seq > @seq
      Order by seq
      
      If @@rowcount = 0 -- end of table
        If @Created = 1 -- at least one function could be created
        Begin 
          Set @seq = 0  -- retry another pass in case some other fonction depends on one just created
          set @Created = 0 -- just to know if the next pass has created nothing
          continue
        End
        Else
          Break
      
      set @sql = 
      '
      Use [<db>_export]
      set ansi_nulls <aNull>;
      Set quoted_identifier <qIden>;
      If object_id("[<sn>].[<mn>]") is null
      Begin
        begin try 
          Execute sp_executeSql @def
        end try
        begin catch
          Print error_number()
          Print error_message()
        end catch
      End
      -- not all errors are caught
      If object_id("[<sn>].[<mn>]") is not null
        Set @created = 1
      Else 
        Set @created = 0
      ' 
      Print 'try create ['+@sn+'].['+@mn+']'
      print '------------------------------------------'
      Set @sql = replace(@sql, '"', '''')
      Set @sql = replace(@sql, '<db>', @dbName)
      Set @sql = replace(@sql, '<sn>', @sn)
      Set @sql = replace(@sql, '<mn>', @mn)
      Set @Sql = replace(@Sql, '<aNull>', case When @aNull = 1 Then 'On' Else 'Off' End)
      Set @Sql = replace(@Sql, '<qIden>', case When @qIden = 1 Then 'On' Else 'Off' End)
      Exec sp_executeSql @Sql, N'@Def nvarchar(max), @created int output', @def, @created output
      If @created = 1 -- certains cas d'erreur ne sont pas capturés
      Begin
        Set @FunctionCreated = @FunctionCreated + 1
        Print 'object '+ @sn+'.'+@mn+ ' created'
        print '------------------------------------------'
        Delete From #defFunc Where seq = @seq -- remove already created function 
      End
      Else
      begin 
        print @sql
        Exec yExecNLog.PrintSqlCode @sql = @def, @numberingRequired = 1
        Print 'object '+ @sn+'.'+@mn+ ' not created'
        print '------------------------------------------'
      end 
    End

    -- ---------------------------------------------------------------------------------------------
    -- Export data one table at the time
    -- ---------------------------------------------------------------------------------------------
  --  Select *  from #TablesToExport 
     
    Set @TableCreated = 0 -- to know if this pass has created at least a table
    Set @seqT = 0
    While (1=1) -- process all tables
    Begin
      Select top 1 
        @sn = sn
      , @tn = tn
      , @seqT = seq
      , @iden = Iden
      , @fgLob = fgLob
      , @fgDat = fgDat
      , @fgDef = fgDef
      From #TablesToExport
      Where seq > @SeqT
      Order by seq
      If @@rowcount = 0 Break

      Set @Info =
      '
      --Export to [<db>_export].[<sn>].[<tn>] à partir de [<Db>].[<sn>].[<tn>]
      '

      Set @sql = replace(@sql, '"', '''')
      Set @sql = replace(@sql, '<db>', @dbName)
      Set @sql = replace(@sql, '<sn>', @sn)
      Set @sql = replace(@sql, '<tn>', @tn)
      Exec yExecNLog.LogAndOrExec 
        @jobNo = @JobNo
      , @context = 'yExport.ExportData'
      , @Info = @Info    
      , @raiseError = @stopOnError

  -----------------------------------------------------
  -- build column list
  -----------------------------------------------------
      Set @ColsSelect = ''
      Set @colsCreateTable = ''
      Set @colsInsertInto = ''

      Set @seqc = 0

      While (1=1)
      Begin

        Select 
          Top 1 @cn = cn
              , @typ = typ
              , @lc = lc
              , @defIden = defIden
              , @DefName = DefName
              , @def = Def
              , @nullSpec = nullSpec
              , @is_computed = is_computed
              , @computedColDef = computedColDef
              , @seqc = OrdCol
        From 
          #ColsTablesAMigr
        Where 
          sn = @Sn And 
          tn = @Tn and 
          ordCol > @seqc 
        Order by ordCol

        If @@rowcount = 0 Break

        -- select list, remove data that can be copied
        If (@typ <> 'timestamp' And @is_computed = 0) 
        Begin
          Set @ColsSelect = 
              @ColsSelect + 
              case 
                when @ColsSelect = ''
                Then ' [<cn>]\n' 
                Else '    ,[<cn>]\n' 
              End 
        End
            
        Set @ColsSelect = Replace(@ColsSelect, '<cn>', @cn)
        Set @ColsSelect = Replace(@ColsSelect, '<lc>', @lc)

        -- liste de colonnes pour into du Insert, dans mode insert, on évite les colonnes timestamp, et les calculées
        If (@typ <> 'timestamp' And @is_computed <> 1) 
        Begin
          Set @colsInsertInto = 
              @colsInsertInto + 
              case 
                when @colsInsertInto = ''
                Then ' ' 
                Else '    ,' 
              End + '['+@cn +']\n' 
        End
        -- liste de colonnes du create table
        -- Les champs n'ont pas tous un défaut, mais ils doivent tous avoir une spec NULL ou Not NULL
        Set @colsCreateTable = 
            @colsCreateTable + 
            case 
              when @colsCreateTable  = ''
              Then ' ' 
              Else '    ,' 
            End + 
            '[<cn>] [<typ>] <lc> <defIden> <defdef> <nullSpec> \n'

        -- si défaut pas spécifié, ôte repère de marqueur de la définition du défaut
        -- sinon ajouter la définition syntaxique
        If @Def = ''
          Set @colsCreateTable = Replace(@colsCreateTable, '<defdef>', '')
        Else  
          Set @colsCreateTable = Replace( @colsCreateTable
                                        , '<defdef>'
                                        , 'CONSTRAINT [DF_<tn>_<cn>] Default <def>')
          
        -- remplace tous les marqueurs  
        Set @colsCreateTable = Replace(@colsCreateTable, '<tn>', @tn)
        Set @colsCreateTable = Replace(@colsCreateTable, '<cn>', @cn)
        If @is_computed <> 1
        Begin
          Set @colsCreateTable = Replace(@colsCreateTable, '<Typ>', @Typ)
          Set @colsCreateTable = Replace(@colsCreateTable, '<lc>', @lc)
          Set @colsCreateTable = Replace(@colsCreateTable, '<defIden>', isnull(@defIden,''))
          Set @colsCreateTable = Replace(@colsCreateTable, '<def>', isnull(@def,''))
          Set @colsCreateTable = Replace(@colsCreateTable, '<nullSpec>', @nullSpec)
        End
        Else
        Begin
          Set @colsCreateTable = Replace(@colsCreateTable, '[<Typ>]', 'as '+@computedColDef)
          Set @colsCreateTable = Replace(@colsCreateTable, '<lc>', '')
          Set @colsCreateTable = Replace(@colsCreateTable, '<defIden>', '')
          Set @colsCreateTable = Replace(@colsCreateTable, '<def>', '')
          Set @colsCreateTable = Replace(@colsCreateTable, '<nullSpec>', '')
        End

      End -- While une colonne de la table
      
  -------------------------------------------------------------------------------------     
  --  Executer le create de la table
  -------------------------------------------------------------------------------------
      Set @Sql = 
      '
      Use [<db>_export]      
      create Table [<sn>].[<tn>]
      (
      <colsCreateTable>
      )
      ON [<FgDat>] TEXTIMAGE_ON [<FgLob>]
      '
      Set @sql = replace(@sql, '<db>', @dbName)
      Set @sql = replace(@sql, '<sn>', @sn)
      Set @sql = replace(@sql, '<tn>', @tn)
      Set @sql = replace(@sql, '<colsCreateTable>', @colsCreateTable)

      If @FgDat = ''
        Set @sql = replace(@sql, 'ON [<FgDat>] ', '')
      Else  
        Set @sql = replace(@sql, '<FgDat>', @FgDat)

      If @FgLob = '' Or (@fgLob = @fgDef)
        Set @sql = replace(@sql, 'TEXTIMAGE_ON [<FgLob>]', '')
      Else  
        Set @sql = replace(@sql, '<FgLob>', @FgLob)

      Set @sql = replace(@sql, '"', '''')
      Set @sql = Replace(@sql, '\n', nchar(10)) -- il y en a dans <colsInsertInto>
      
      Begin Try
        Exec yExecNLog.LogAndOrExec 
          @jobNo = @JobNo
        , @context = 'yExport.ExportData'
        , @Info = 'Table creation'
        , @sql = @Sql    
        , @raiseError = 1  -- must catch the error

        Set @TableCreated = @TableCreated + 1
        Delete 
        From #TablesToExport
        Where seq = @SeqT

      End try
      Begin catch
      
        print error_message()
        Continue -- Jump to next table creation
      
      End catch

      -- decide if data is going to be pipelined through a view
      Set @sql = 
      '
      Use <db>
      If exists
         (
         select * 
         from sys.views 
         where name = "<tn>"
           And Schema_name(schema_id) = "yExport_<sn>"
         )
        Set @schemaAlt = 1
      Else
        Set @schemaAlt = 0
      '  
      Set @sql = replace(@sql, '<db>', @dbName)
      Set @sql = replace(@sql, '<sn>', @sn)
      Set @sql = replace(@sql, '<tn>', @tn)
      Set @sql = replace(@sql, '"', '''')
      Exec sp_executeSql @sql, N'@schemaAlt int output', @schemaAlt = @schemaAlt output
      
  -------------------------------------------------------------------------------------     
  --  Executer le insert / select
  -------------------------------------------------------------------------------------
      Set @sql = 
      '
      declare @d nvarchar(25); set @d = convert(nvarchar(25), getdate(), 121)
      raiserror ("Start export to [<db>_export].[<sn>].[<tn>] at %s",10,1, @d) with nowait -- force output no error
      '
      Set @sql = replace(@sql, '<db>', @dbName)
      Set @sql = replace(@sql, '<sn>', @sn)
      Set @sql = replace(@sql, '<tn>', @tn)
      Set @sql = replace(@sql, '"', '''')
      Exec sp_executeSql @sql -- progress report only

      Set @sql = -- prépare un insert /select complet
      '
      Declare @nb Int
      ------------------------------------------------------------
      Set identity_insert [<db>_export].[<sn>].[<tn>] on
      
      
      Insert into [<db>_export].[<sn>].[<tn>] with (tablock)
      (
      <colsInsertInto>
      )
      Select 
      <colsSelect>
      from [<Db>].[<sn>].[<tn>]      
      
      
      Set @nb = @@rowcount
      Set identity_insert [<db>_export].[<sn>].[<tn>] off
      checkpoint   -- Empty the log in simple recovery
      ------------------------------------------------------------
      declare @d nvarchar(25); set @d = convert(nvarchar(25), getdate(), 121)
      declare @s nvarchar(25); set @s = convert(nvarchar(25), @nb)
      raiserror ("End export at %s. %s rows exported to [<db>_export].[<sn>].[<tn>] ",10,1, @d, @s) with nowait -- force output no error
      '

      -- pipeline data through a pre-defined view in a predefined schema
      If @schemaAlt = 1
        Set @sql = REPLACE(@sql, '[<Db>].[<sn>].[<tn>]', '[<Db>].[yExport_<sn>].[<tn>]')

      If @iden = 0 -- si pas de définition de colonne identity enlève, mise là juste en mode Insert Select
      Begin
        -- ôte instructions relatives à la gestion de l'insertion de la clause identity
        Set @sql = replace(@sql, 'Set identity_insert [<db>_export].[<sn>].[<tn>] on', '')
        Set @sql = replace(@sql, 'Set identity_insert [<db>_export].[<sn>].[<tn>] off', '')
      End  
      Set @sql = replace(@sql, '<colsInsertInto>', @ColsInsertInto)
      Set @sql = replace(@sql, '<colsSelect>', @ColsSelect)
      Set @sql = replace(@sql, '<db>', @dbName)
      Set @sql = replace(@sql, '<sn>', @sn)
      Set @sql = replace(@sql, '<tn>', @tn)
      Set @sql = replace(@sql, '"', '''')
      Set @sql = Replace(@sql, '\n', nchar(10)) -- il y en a dans <colsInsertInto>

      Exec yExecNLog.LogAndOrExec 
        @jobNo = @JobNo
      , @context = 'yExport.ExportData'
      , @Info = 'Table load by insert/select'
      , @sql = @Sql    
      , @raiseError = @stopOnError

      Set @typDesc = 'Clustered' -- traite en ordre clustered, puis après non clustered
      Set @in = ''
      Set @ColIdxChar = 0
      
      While (1=1) -- un index de la table à recréer
      Begin
        Select Top 1 @in = IdxName, @iUniq = is_unique, @pk = Is_primary_key, 
                     @IUniqC = is_unique_constraint, @fgIdx=FgIdx, @IndexOnView = IndexOnView
        From #Indexes
        Where sn = @Sn And tn = @Tn and type_desc = @typDesc and IdxName > @in
          And IndexOnView = 0
        Order by sn, tn, IdxName

        If @@rowcount = 0 
        Begin
          If @typDesc = 'Clustered' 
          Begin 
            Set @typDesc = 'NonClustered' -- traite ensuite nonclustered
            Set @in = '' -- recommence à parcourir les index en ordre
            continue
          End  
          Else   
            Break
        End     
        
        -- détermine si l'index a des colonnes de type charactère pour éviter 
        -- de vérifier l'unicité de l'index à cause de la cédille si elle n'a 
        -- pas de champ texte
        
        Select top 1 @ColIdxChar = ColIdxChar
        from #IndexesCols
        Where sn = @Sn And tn = @Tn And IdxName = @In And ColIdxChar = 1
        If @@rowcount = 0 Set @ColIdxChar = 0

        -- fabriquer liste de colonnes de l'index
        Set @Cols = ''
        Set @LigCols = ''
        Set @seqc = 0

        While (1=1)  -- une colonne de l'index à attribuer
        Begin
          Select Top 1 @cn = cn, @seqc = Ko
          From #IndexesCols
          Where sn = @Sn And tn = @Tn And IdxName = @In and Ko > @seqc
          Order by ko

          If @@rowcount = 0 Break
          
          Set @Cols = 
              @Cols + 
              case 
                when @Cols = ''
                Then '' 
                Else ' ,' 
              End + '[' + @cn + ']'
              
          Set @ligCols = @ligCols + case When @ligCols = '' Then '' Else ' ,' End+'[' + @cn + ']' 
              
        End -- While une colonne
        
        Set @sql = 
        '
        Use [<db>_export]
         ' +
         Case 
           When @Pk = 1 Then 
           '
           Alter table [<sn>].[<tn>] add constraint [<IdxN>] primary key <ikc>
           (<cols>) 
           With (FILLFACTOR = 90) ON [<FgIdx>]
           '
           When @iUniqC = 1 Then 
           '
           Alter table [<sn>].[<tn>] add constraint [<IdxN>] unique 
           (<cols>) 
           With (FILLFACTOR = 90) ON [<FgIdx>]
           '
           Else
           '
           Create <iUniq> <ikc> Index [<IdxN>] On [<sn>].[<tn>]  
           (<cols>) 
           With (FILLFACTOR = 90) ON [<FgIdx>]
        '
        End -- case
        
        Set @sql = replace(@sql, '<db>', @dbName)
        Set @sql = replace(@sql, '<sn>', @sn)
        Set @sql = replace (@sql, '<tn>', @tn)
        Set @sql = replace (@sql, '<IdxN>', @In)
        Set @sql = replace (@sql, '<ikc>', @TypDesc)
        Set @sql = replace (@sql, '<iUniq>', case When @iUniq = 1 Then 'Unique' Else '' End)
        Set @sql = replace (@sql, '<cols>', @Cols)
        Set @sql = replace (@sql, '<ligcols>', @LigCols)
        Set @sql = replace (@sql, '<pk>', Str(@pk,1))
        Set @sql = replace (@sql, '<iUniqC>', Str(@iUniqC,1))

        If @FgIdx = ''
          Set @sql = replace(@sql, 'ON [<FgIdx>] ', '')
        Else  
          Set @sql = replace(@sql, '<FgIdx>', @FgIdx)
        
        Set @sql = replace (@sql, '"', '''')
        Set @sql = @sql + NCHAR(10)+ 'checkpoint'
        
        Exec yExecNLog.LogAndOrExec 
          @jobNo = @JobNo
        , @context = 'yExport.ExportData'
        , @Info = 'Recreate table indexes'
        , @sql = @Sql    
        , @raiseError = @stopOnError
        
      End -- While un index

    End -- While Une table à traiter
  
    If exists(Select * from #TablesToExport) -- no table or scalar function could be created this 
                    -- must stop because this is not due to a cross dependencies problem between both
    Begin     
      Select sn, tn from #TablesToExport           
      raiserror ('Some tables/index could be exported',11,1)
    End  
    Else
      Break -- no more tables
      
  End -- Creation d'une table et/ou au moins une fonction scalaire fonctionne

----------------------------------------------------------------------------------
-- recreate auto-generated stats for all tables
----------------------------------------------------------------------------------
  Set @seq = 0
  While (1=1) -- un index de la table à recréer
  Begin
    
    Select Top 1 @seq = seq, @sn = sn, @tn = tn, @cn = cn
    From #Stats 
    Where seq > @seq 
    Order by seq
    
    If @@ROWCOUNT = 0
      break
    
    Set @sql =
    '
    Use [<db>_export]
    declare @c int
    Select @c = count(distinct [<cn>])
    From (Select [<sn>].[<tn>].[<cn>] From [<sn>].[<tn>] tablesample(10 percent)) as x
    '
    Set @sql = Replace(@sql, '<db>', @dbName)
    Set @sql = Replace(@sql, '<sn>', @Sn)
    Set @sql = Replace(@sql, '<tn>', @tn)
    Set @sql = Replace(@sql, '<cn>', @cn)
    Set @sql = Replace(@sql, '"', '''')
    
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportData'
    , @Info = 'Optimizer stats recreate'
    , @sql = @Sql    
    , @raiseError = @stopOnError

  End -- While
  
----------------------------------------------------------------------------------
-- rebatir les clés étrangères des tables s'il y a lieu
----------------------------------------------------------------------------------
  Set @seqFk = 0    
  While (1=1)
  Begin
    Select Top 1 @Ks = Sn, @tn = Tn, @Kn = Kn, @seqFk = Seq,
                 @FKOnClause = 
                 Case When UPDATE_RULE <> 'NO ACTION' Then ' ON UPDATE '+UPDATE_RULE ELSE '' END +
                 Case When DELETE_RULE <> 'NO ACTION' Then ' ON DELETE '+DELETE_RULE ELSE '' END ,
                 @is_not_trusted = is_not_trusted
    From #RefConstraints
    Where seq > @seqFk
    order by seq
    
    If @@rowcount = 0 Break

    -- fabriquer liste de colonnes de la reference aux colonnes
    Set @Cols = ''
    Set @ucols = ''
    Set @seqc = 0

    While (1=1) -- une colonne pour la reference de cle etrangere
    Begin
      Select Top 1 @cn = cn, @seqc = OrdCol, @Usn = Usn, @Utn = Utn, @Ucn = Ucn
      From #ColsRefConstraints
      Where sn = @Ks And tn = @Tn and @Kn=Kn and OrdCol > @seqC
      Order by sn, tn, ordCol

      If @@rowcount = 0 Break
      
      Set @Cols = @Cols + 
           case 
             when @Cols = ''
             Then '    ' 
             Else '  , ' 
           End + '['+ @cn + ']'
      Set @uCols = @uCols + 
          case 
            when @uCols = ''
            Then '    ' 
            Else '  , ' 
          End + '['+ @uCn + ']'
    End -- While une colonne
    
    Set @sql =
    '
    Use [<db>_export]
    Alter table [<ks>].[<tn>] <nocheck> add constraint [<Kn>] FOREIGN KEY 
    (<cols>)
    REFERENCES [<Usn>].[<Utn>]
    (<uCols>)
    <FkOnClause>;
    Alter table [<ks>].[<tn>] NoCheck Constraint [<Kn>];
    Checkpoint
    '
    If @is_not_trusted = 0 
    Begin
      Set @sql = replace (@sql, '<nocheck>', '')
      Set @sql = replace (@sql, 'Alter table [<sn>].[<tn>] NOCHECK Constraint [<Kn>];', '')
    End  
    Else  
      Set @sql = replace (@sql, '<nocheck>', 'WITH NOCHECK')
      
    Set @sql = replace(@sql, '<db>', @dbName)
    Set @sql = replace (@sql, '<ks>', @ks)
    Set @sql = replace (@sql, '<tn>', @tn)
    Set @sql = replace (@sql, '<Kn>', @Kn)
    Set @sql = replace (@sql, '<cols>', @Cols)
    Set @sql = replace (@sql, '<Usn>', @uSn)
    Set @sql = replace (@sql, '<Utn>', @utn)
    Set @sql = replace (@sql, '<uCols>', @uCols)
    Set @sql = replace (@sql, '<FkOnClause>', @FkOnClause)

    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportData'
    , @Info = 'Recreate referential constraints'
    , @sql = @Sql    
    , @raiseError = @stopOnError

  End -- While une clé étrangère à traiter

  raiserror('Shrint the log',10,1) 


  declare @logN sysname
  Set @sql =
  '
  use [<db>_Export]
  Select @logn = name from sys.database_files where type_desc = "LOGN"
  '
  Set @sql = replace(@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')
  Exec sp_executeSql @Sql, N'@logN sysname output', @logn = @logn output

  Set @sql =
  '
  use [<db>_Export]
  dbcc shrinkfile("<logn>") with NO_INFOMSGS
  '
  Set @sql = replace(@sql, '<db>', @dbName)
  Set @sql = replace(@sql, '"', '''')
  Set @sql = replace(@sql, '<logn>', @logn)
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportData'
  , @Info = 'Reset log file'
  , @sql = @Sql    
  , @raiseError = @stopOnError

  End try 

  begin catch
    set @Info = ERROR_MESSAGE() + ' (ExportData)'
    raiserror(@Info, 11, 1) 
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportData'
    , @err = 'Failure to complete ExportData'
  end catch

End -- Export.ExportData
GO

If objectpropertyEx(object_id('yExport.ExportCode'), 'isProcedure') = 1 
  Drop procedure yExport.ExportCode
GO
create proc yExport.ExportCode 
  @dbName    sysname
, @stopOnError Int = 1  
, @jobNo Int
as
Begin
  -- On boucle sur la création des objets car certains ne peuvent être crées avant que d'autres le soient
  -- ex: les vues ou fonctions peuvent dépendre de d'autres vues ou fonctions
  -- On crée ensuite les procédures qui bien qu'elles dépendent de d'autres procédures peuvent être créées
  -- mais la liste des dépendances n'est alors pas complète
  -- On repasse la création des procédures pour remédier à ce problème
  -- Le triggers n'ont qu'à être créés qu'une fois
  -- Le principe d'arrêt du traitement consiste à retirer de la table temporaire de copie de 
  -- définition des objets, tous les objets crées avec succès
  
  set nocount on

  declare 
    @seq  int            -- pour séquencer le traitement selon l'ordre voulu
  , @id   int            -- id de l'objet pour identifiant unique de l'objet
  , @n    sysname        -- nom sp ou fonction
  , @sc   sysname        -- nom du schema proprio
  , @typ_Desc sysname    -- identification SQL du type de code, provient de sys.objetcs
  , @ModuleTyp sysname        -- identifie si sp ou vue/fonction (en abrégé)
  , @anull bit           -- mode uses_ansi_null
  , @qiden bit           -- mode uses_quoted_identifier
  , @Def  nvarchar(max)   -- définition de la SP ou fonction
  , @sql  nvarchar(max) 
  , @sql2 nvarchar(max) 
  , @ErreurNative int
  , @Info nvarchar(max)
  , @nbSqlOk int
  , @msgSql nvarchar(max)
  , @sqlMain nvarchar(max)
  
---------------------------------------------------------------------------------------------------
-- preparer la BD pour la migration du code SQL, faire une copie du code dans Bd qui va être migrée
---------------------------------------------------------------------------------------------------
  create table #SqlCode -- list all proc and function 
  (
    seq int          -- sequence voulue du traitement 
  , id  int          -- id de l"objet pour relire dans même ordre
  , sc  sysname      -- schema de l"object
  , n   sysname      -- nom sp ou fonction
  , typ_Desc sysname -- vrai type d"origine
  , typ sysname      -- identifie si sp ou fonction pour drop
  , anull Bit        -- identifie si procédure créé avec ansi null on = 1
  , qiden Bit        -- identifie si procédure créé avec quote identifier on = 1
  , msgSql nvarchar(1000) NULL -- conserver dernier message d"erreur
  , Def nvarchar(max)     -- définition de la vue, trigger, SP ou fonction
  )
  Create unique clustered index iPkSp on #SqlCode (Seq)
  
  declare @iTyp int; set @iTyp = 0
  
  While (1=1)
  Begin
    ;With codeType (iTyp, ModuleTyp) as (Select 1, 'VUEF' Union all Select 2, 'PROC' Union all Select 3, 'TRIG')
    Select top 1 @iTyp = ityp, @Moduletyp = ModuleTyp
    From codeType 
    Where iTyp > @iTyp 
    Order by iTyp
    
    If @@rowcount = 0 break
    
    Set @sql = 
    '
    Use [<Db>]

    truncate table #SqlCode 
    ;With SqlCode
    as
    (
    Select 
      M.object_id as id
    , isnull (SCHEMA_NAME (Ob.schema_id), "") as sc
    , object_name(M.object_id) as n
    , OB.type_desc as typ_desc
    , Case 
        When TYPE_DESC Like "SQL%PROCEDURE" Then "Proc"
        When TYPE_DESC Like "SQL%TRIGGER"    Then "Trig"
        Else "VueF"
      End as typ
    , M.definition as Def
    , M.uses_ansi_nulls as aNull
    , M.uses_quoted_identifier as qIden
    from 
      sys.sql_modules M
      join
      sys.objects OB
      On OB.object_id = M.object_id
    )  
    Insert into #SqlCode (seq, id, sc, n, typ_desc, typ, def, anull, qiden)
    Select
      row_number() OVER (ORDER BY sc, n, id) as seq
    , id, sc, n, typ_desc, typ, def, anull, qiden
    From 
      SqlCode
    where objectpropertyEx(id, "isMsShipped") = 0 
      and typ = "<ModuleTyp>"

    Select seq, "[<Db>_export].["+sc+"].["+n+"]"
    from #sqlCode
    '
    Set @sql = replace(@sql, '<db>', @dbName)
    Set @sql = replace(@sql, '"', '''')
    Set @sql = replace(@sql, '<ModuleTyp>', @ModuleTyp)
    
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportCode'
    , @Info = 'Get SQL code'
    , @sql = @Sql    
    , @raiseError = @stopOnError


  -- ------------------------------------------------------------------------------------------------
  -- loop to recreate objects
  -- ------------------------------------------------------------------------------------------------
    Set @nbSqlOk = 0 
    Set @seq = 0

    Declare @pass int; set @pass = 1
    Declare @created int; set @created = 0 

    while (1=1) -- there is a sp to create
    Begin

      -- read sql module definition
      select top 1 @seq = seq, @Id = id, @sc = sc, @n = n, @ModuleTyp = typ, @typ_desc = typ_desc
                   , @aNull = aNull, @qIden = qIden, @def = def
      from #SqlCode
      Where  seq > @seq
      Order by seq

      if @@rowcount = 0 -- reach list end
      Begin
        If @ModuleTyp= 'Proc'
        Begin
          If @pass > 1
            Break
          Else
          Begin 
            Set @seq = 0 -- redo a pass to have clean sp dependencies
            Set @pass = @pass + 1
            continue
          End  
        End    
        If @ModuleTyp= 'VueF'
        Begin
          If @created = 0 -- nothing could be created, useless to continue
            Break
          Else
          Begin
            Set @created = 0
            Set @seq = 0 -- redo a pass in attempt to get more dependent objects created
            continue
          End  
        End    
        If @ModuleTyp= 'Trig' -- trigger are created last, no worth keep trying again
          Break
      End
        
      set @sqlMain = 
      '
      Use [<db>_export]
      set ansi_nulls <aNull>;
      Set quoted_identifier <qIden>;
      begin try 
        exec YourSqldba.f$.DropObj "[<db>_export].[<sc>].[<n>]", @showdrop = 1
        Execute sp_executeSql @def
      end try
      begin catch
        Print "Error: "+str(error_number()) + " " + error_message()
      end catch
      -- not all errors are caught
      If object_id("[<sc>].[<n>]") is not null
        Set @created = 1
      Else 
        Set @created = 0
      ' 
      print 'try create: '+@dbName+'_export.'+@sc+'.'+@n
      Set @sqlMain = replace(@sqlMain, '"', '''')
      Set @sqlMain = replace(@sqlMain, '<aNull>', case When @aNull = 1 Then 'On' Else 'Off' End)
      Set @sqlMain = replace(@sqlMain, '<qIden>', case When @qIden = 1 Then 'On' Else 'Off' End)
      Set @sqlMain = REPLACE(@sqlMain, '<db>', @dbName)
      Set @sqlMain = REPLACE(@sqlMain, '<n>', @n)
      Set @sqlMain = REPLACE(@sqlMain, '<sc>', @sc)
        
      Exec sp_executeSql @Sqlmain, N'@Def nvarchar(max), @created int output', @def, @created output

      If @created = 1 -- certains cas d'erreur ne sont pas capturés
      Begin
        print 'create succeeded'
        If @pass = 2 Or @ModuleTyp in ('VUEF', 'TRIG')
          Delete From #SqlCode Where seq = @seq
      End
      Else
      begin 
        Print 'Object '+@n + ' cannot be created yet '
        Print @sqlMain
        Exec yExecNLog.PrintSqlCode @sql = @def, @numberingRequired =0
      end 


    End  -- while

    
  End -- While there is a type of code to do
  
  -- TODO : Recreate indexes on view if any here
  
End -- yExport.ExportCode
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
--------------------------------------------------------------------------------------------------------
-- Procedure maitresse qui migre les code utilisateurs et les droits
--------------------------------------------------------------------------------------------------------
if objectpropertyEx(object_id('yExport.ExportSecur'), 'isProcedure') = 1 
  Drop Procedure yExport.ExportSecur
GO
Create Procedure yExport.ExportSecur
  @dbName sysname
, @stopOnError Int = 1  
, @jobNo Int
as
Begin
  Set nocount on

  declare @etp nvarchar(4) Set @etp = 'Secu' -- simplifie appel de la proc de logExec et logErr

  declare 
    @sql nvarchar(max) 
  , @suffixe sysname  
  -- var to recreate ysers
  , @Usr    sysname
  , @Uid    smallInt
  , @logN   sysname      
  , @default_schema sysname
  , @owning_principal_id int

  -- var to recreate perms to users and roles
  , @Seq    int
  , @action nvarchar(50) 
  , @perms  nvarchar(256)
  , @TypObj Char(1)
  , @obj    sysname 
  , @col    sysname 
  , @SomeUsers nvarchar(max) 

  -- var to create roles and roles members
  , @r      sysname
  , @rM     sysname
  , @seqM   Int
  , @Info    nvarchar(max)

  Begin try


  -- get actual users and corresponding login name
  
  Create Table #princ -- users list
  (
    Usr             sysname  collate database_default Not NULL 
  , uid             int
  , logN            sysname  collate database_default NULL 
  , default_schema  sysname  collate database_default null
  , owning_principal_id int null
  )

  Set @sql = 
   '
   Use [<db>]

   insert into #princ 
   Select 
     p.name   collate LATIN1_GENERAL_CI_AI as UserName 
   , p.principal_id  
   , SUSER_SNAME(sid)
   , p.default_schema_name
   , p.owning_principal_id
   From
     [<Db>].sys.database_principals P
   Where p.type_desc = "SQL_USER"
     And p.default_schema_name is not null
     And not exists(Select * from [<Db>_export].sys.database_principals as E Where E.name = P.Name collate Latin1_general_ci_ai)
   '
   Set @sql = replace(@sql,'<db>', @dbName)
   Set @sql = replace(@sql,'"', '''')

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportSecur'
  , @Info = 'Get users names'
  , @sql = @Sql    
  , @raiseError = @stopOnError



---------------------------------------------------------------------------------------------------------
-- enum database roles and their members
---------------------------------------------------------------------------------------------------------
  Create Table #Roles
  (
    RoleName Sysname primary key clustered
  , Principal_id Int
  )

  Create Table #RoleMembers
  (
    Seq         int primary key clustered 
  , RoleName    Sysname
  , RoleMember  sysname
  )


  Set @sql=
  '
  Use [<Db>]

  Insert into #roles
  select PSrc.Name as RoleName, PSrc.principal_Id
  from sys.database_principals PSrc
  where type_desc = "database_role"
    And not exists(Select * from [<Db>_export].sys.database_principals as E Where E.name = PSrc.Name collate Latin1_general_ci_ai)
    
  Insert into #RoleMembers
  Select 
    ROW_NUMBER() OVER(Order By R.RoleName, M.Name) as Seq
  , R.RoleName collate Latin1_general_ci_ai as RoleName
  , M.Name collate Latin1_general_ci_ai as Name
  From 
    #roles R

    JOIN
    sys.database_role_members RM
    ON RM.Role_Principal_id = R.Principal_id 

    JOIN
    sys.database_principals M
    ON M.Principal_id = RM.Member_Principal_id And
       M.type_desc <> "application_role"
  '
  Set @sql = replace (@sql, '<db>', @dbName)
  Set @sql = replace (@sql, '"', '''')

  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportSecur'
  , @Info = 'Keep roleMembership'
  , @sql = @Sql    
  , @raiseError = @stopOnError

----------------------------------------------------------------------------------------------------------
-- Make a compressed list on rights to make less GRANT/DENY instructions
----------------------------------------------------------------------------------------------------------

  Create Table #RightsToApply 
  (
    Seq    int primary key clustered 
  , action nvarchar(50) NOT NULL
  , perms  nvarchar(256) NOT NULL
  , TypObj Char(1)
  , obj    sysname NULL
  , col    sysname NULL
  , SomeUsers nvarchar(max) NOT NULL
  )

  Create Table #Privs
  (
    Seq    int primary key clustered 
  , action nvarchar(50) NOT NULL
  , perm   nvarchar(256) NOT NULL
  , TypObj Char(1)
  , obj    sysname NULL
  , col    sysname NULL
  , ToWho  nvarchar(max) NOT NULL
  )

  Set @sql=
  '
  Use [<Db>]

  ;With ObjectIds (ObjId)
  as
  (
  Select object_Id(name) as ObjId 
  From sys.tables
  union all
  Select object_Id -- exclure les vues retournées aussi par information_schema.table
  From sys.sql_modules 
  Where objectpropertyEx(object_id, "IsView") = 0
  )
  , AllPrivs
  as
  (
  select -- lire les droits qui ne sont pas spécifique à la colonne
    state_desc collate LATIN1_GENERAL_CI_AI as Action
  , permission_name collate LATIN1_GENERAL_CI_AI as Perm
  , Case 
      When objectpropertyex(major_Id, "isUserTable") =1 Or
           objectpropertyex(major_Id, "isView") =1 
      Then "Q"
      Else "M"
    End collate LATIN1_GENERAL_CI_AI as TypObj
  , object_name(major_Id) collate LATIN1_GENERAL_CI_AI as Obj
  , NULL as Col -- pas une colonne
  , user_name(grantee_principal_id) collate LATIN1_GENERAL_CI_AI as toWho
  from 
    ObjectIds as Objs
    Join
    sys.database_permissions P
    ON P.major_id = Objs.ObjId
  Where 
    minor_id = 0 And -- zéro if no column specific privileges
    class_desc = "OBJECT_OR_COLUMN"
  UNION ALL
  select -- add specific columns rights
      state_desc
    , permission_name
    , Case 
        When objectpropertyex(major_Id, "isUserTable") =1 Or
             objectpropertyex(major_Id, "isView") =1 
        Then "Q"
        Else "M"
      End
    , object_name(major_Id)
    , COL_NAME (Object_id, Column_id)
    , user_name(grantee_principal_id)
  from 
    sys.columns TC
    Join
    sys.database_permissions P
    ON P.major_id = Tc.Object_id And
       P.minor_id = Tc.Column_id
  )
  Insert into #Privs (Seq, action, perm, TypObj, obj, col, toWho)
  Select 
    Row_number() over (order by Obj)
  , Action
  , perm
  , typObj
  , obj
  , col
  , toWho
  From AllPrivs
  ' 
  Set @sql = replace(@sql,'<db>', @dbName)
  Set @sql = replace(@sql,'"', '''')
  
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportSecur'
  , @Info = 'Keep user/role permissions'
  , @sql = @Sql    
  , @raiseError = @stopOnError

  Set @Uid = 0 -- to get to #1 which is dbo and which must be processed first
  While (1=1)
  Begin

    Select -- read next user
    Top 1 
      @Usr = Usr    
    , @logN = LogN
    , @Uid = Uid
    , @default_schema = default_schema
    , @owning_principal_id = owning_principal_id
    From 
      #princ
    Where Uid > @Uid
    Order by Uid

    If @@rowcount = 0 Break -- no more to read

    If @usr = 'dbo' -- ordre de traitement des users fait que celui-ci est traité en premier
    Begin
      Set @sql =
      '
      use [<db>_export];
      ALTER AUTHORIZATION ON Database::[<db>_export] To [<LogN>];
      '
      Set @sql = replace(@sql,'<db>', @dbName)
      Set @sql = replace(@sql,'<LogN>', ISNULL(@LogN, 'YourSQLDba'))
      Set @sql = replace(@sql,'"', '''')

      Exec yExecNLog.LogAndOrExec 
        @jobNo = @JobNo
      , @context = 'yExport.ExportSecur'
      , @Info = 'Set Db Owner'
      , @sql = @Sql    
      , @raiseError = @stopOnError
      
      Continue
    End

    -- if here user is not dbo
    Set @sql = ''
    
    If @Usr <> 'Guest'  
    Begin
      -- user not aliased to dbo
      If @logN <> ''
        Set @sql =
        '
        use [<db>_export];
        Create user [<Usr>] For Login [<logN>] with default_schema = <default_schema>
        '
      Else
        Set @sql =
        '
        -- user is orphaned or aliased to dbo
        use [<db>_export];
        Create user [<Usr>] Without Login -- user is aliased to dbo recreate it without login          
        '
    End
    else
    Begin
      If exists(Select * 
                from Sys.database_permissions 
                where grantee_principal_id = user_id('guest') 
                  and type = 'co' 
                  and state = 'G') 
      Begin  
        Set @sql =
        '
        use [<db>_export];
        Grant connect to guest  
        '
      End
    End  

    Set @sql = replace(@sql,'<db>', isnull(@dbName, ''))
    Set @sql = replace(@sql,'<usr>', isnull(@Usr, ''))
    Set @sql = replace(@sql,'<logN>', isnull(@logN, ''))
    If @default_schema is null
      Set @sql = replace (@sql, 'with default_schema = <default_schema>', '')
    Else
      Set @sql = replace (@sql, '<default_schema>', @default_schema)
      
    Set @sql = replace(@sql,'"', '''')

    if @sql <> ''     
      Exec yExecNLog.LogAndOrExec 
        @jobNo = @JobNo
      , @context = 'yExport.ExportSecur'
      , @Info = 'create user '
      , @sql = @Sql    
      , @raiseError = @stopOnError

  End -- While user to create

  Set @r = '' -- read first role
  While (1=1)
  Begin
    Select top 1 @r = RoleName 
    From #Roles
    Where RoleName > @r
    Order by RoleName

    If @@rowcount = 0 Break -- si plus rien quitter

    Set @sql = 
    '
    use [<db>_export];
    exec ("Create ROLE <role> AUTHORIZATION dbo") 
    '
    Set @sql = replace (@sql, '<Role>', @r)
    Set @sql = replace (@sql, '<db>', @dbName)
    Set @sql = replace (@sql, '"', '''')

    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportSecur'
    , @Info = 'create role'
    , @sql = @Sql    
    , @raiseError = @stopOnError
  End -- while

  Set @SeqM = 0 -- amorce lecture des membres de roles
  While (1=1)
  Begin
    Select top 1 @r = RoleName, @rM = RoleMember, @SeqM = Seq
    From #RoleMembers
    Where Seq > @SeqM
    Order by Seq
    If @@rowcount = 0 Break

    Set @sql = 
    '
    use [<db>_export];
    If "<membre>" <> "dbo" 
      Exec sp_addrolemember "<role>", "<membre>"
    '
    Set @sql = replace (@sql, '<db>', @dbName)
    Set @sql = replace (@sql, '<Role>', @r)
    Set @sql = replace (@sql, '<membre>', @rM)
    Set @sql = replace(@sql,'"', '''')
    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportSecur'
    , @Info = 'Add role member'
    , @sql = @Sql    
    , @raiseError = @stopOnError

  End -- While il y a un membre de role à ajouter à un role

-- *****************************************************************

--declare @sql nvarchar(max)
--declare @dbName sysname 
--set @dbName=db_name()
--drop table #RightsToApply
----------------------------------------------------------------------------------------------------------
-- Réattribuer les droits, lister, compresser en moins d'instructions GRANT/DENY, ré-exécuter GRANT / DENY
-- Droits lus de la Bd à migrer
-- C'est un ensemble de requêtes avec tables temporaires assez compliqué
-- On ne peut pas couper la batch en moins car les tables #temporaire sont créées par select into
-- et cesseraient d'exister après 
----------------------------------------------------------------------------------------------------------
  Set @sql=
  '
  use [<db>]

  ;With TabAndProcPriv
  as
  (
  Select
    Action
  , Convert
    (
      nvarchar(128)
    , Stuff -- remove starting comma from the list
      ( -- put together perms by column, user
      Max(Case When Perm = "Select " Then ", Select " Else "" End) +
      Max(Case When Perm = "Insert " Then ", Insert " Else "" End) +
      Max(Case When Perm = "Update " Then ", Update " Else "" End) +
      Max(Case When Perm = "Delete "  Then ", Delete " Else "" End) +
      Max(Case When Perm = "Execute " Then ", Execute " Else "" End) +
      Max(Case When Perm = "References " Then ", References " Else "" End) 
      , 1
      , 1
      , ""
      ) 
    ) as Perms
  , TypObj
  , Obj
  , Col
  , toWho
  From 
    #Privs
  group by Action, TypObj, Obj, Col, toWho
  )
  Select 
      Action
    , Perms
    , TypObj
    , Obj
    , Col
    , toWho 
    -- give unique sequence number group to every 15 users
    , ROW_NUMBER() OVER(partition By Action, perms, typObj, Obj, Col Order by toWho) / 15 AS "PermGroup"
  into #Pa  
  From
    TabAndProcPriv
    
  create clustered index iPa on #Pa  (action, perms, obj, permGroup)

  -- compact rights statement by keeping the same set of rights on one or more users
  -- use premGroup generated previously to do that
  
  Truncate table #RightsToApply
  Insert into #RightsToApply 
  (
      Seq
    , action 
    , perms  
    , TypObj 
    , obj    
    , col    
    , SomeUsers
  )
  Select
      -- order rights so that grants are performed before deny so action column order is set descending
      ROW_NUMBER() OVER(Order by Action Desc, perms, Obj, Col) 
    , Action
    , Perms
    , TypObj 
    , Obj
    , col
    -- put together users that receive the same set of rights on the same objects
    , stuff 
      (
        (
         -- nom colonne interprétée par XPATH, 
         -- ici text() spécifie que c"est le texte de l"élément et pas son nom ex: nomElem
         -- truc SQL2005 pour fusionner data de plusieurs lignes
         select ", ["+cast(D.toWho as varchar(max))+"]" as [text()]  
         from #Pa D
         Where 
           D.Action = Pa.Action And D.perms = Pa.Perms And D.Obj = Pa.Obj And 
           ISNULL(D.col, "") = ISNULL(Pa.Col,"") And
           D.PermGroup = Pa.PermGroup
         ORDER By D.toWho
         FOR XML PATH("") 
         )
       , 1
       , 2
       , ""
    ) as SomeUsers
  From
    (
    Select Distinct Action, Perms, TypObj, Obj, Col, PermGroup
    From #Pa
    ) as PA
  '
  Set @sql = replace(@sql,'<db>', @dbName)
  Set @sql = replace(@sql,'"', '''')
  Exec yExecNLog.LogAndOrExec 
    @jobNo = @JobNo
  , @context = 'yExport.ExportSecur'
  , @Info = 'Get rights info'
  , @sql = @Sql    
  , @raiseError = @stopOnError

--  Select * from #RightsToApply

  Set @seq = 0 -- amorce pour lecture des attribution de droits
  While (1=1)
  Begin
    Select TOP 1
      @seq = seq
    , @action = action
    , @perms = perms
    , @typObj = typObj
    , @obj = obj
    , @col = col
    , @SomeUsers = SomeUsers
    From #RightsToApply
    Where seq > @seq
    Order By seq

    if @@rowcount = 0 BreaK

    -- applique sur BD de destination les droits
    Set @sql = 
    '
    Use [<db>_export]; 
    If object_Id("[<obj>]") IS NOT NULL
      <action> <perms> ON OBJECT::[<obj>] ([<Col>]) 
      To <SomeUsers> <WithGrantOpt>
    '
    Set @Sql = replace(@sql, 
                       '<action>', 
                       case 
                         When @action <> 'GRANT_WITH_GRANT_OPTION' 
                         Then @action 
                         Else 'GRANT' 
                       End
                      )
    Set @Sql = replace(@sql, 
                       '<WithGrantOpt>', 
                       case
                         When @action <> 'GRANT_WITH_GRANT_OPTION' 
                         Then '' -- efface tag option
                         Else 'WITH GRANT OPTION' -- sinon la met
                       End
                      )
    Set @Sql = replace(@sql, '"', '''')
    Set @Sql = replace(@sql, '<perms>', @perms)
    Set @Sql = replace(@sql, '<obj>', @obj)
    Set @Sql = replace(@sql, '<SomeUsers>', @SomeUsers)
    If @col is NULL      
      Set @Sql = replace(@sql, '([<Col>])', '')
    Else
      Set @Sql = replace(@sql, '<Col>', @col)

    Set @sql = replace(@sql,'<db>', @dbName)

    Exec yExecNLog.LogAndOrExec 
      @jobNo = @JobNo
    , @context = 'yExport.ExportSecur'
    , @Info = 'Apply privileges'
    , @sql = @Sql    
    , @raiseError = @stopOnError

  End -- tant que des droits à appliquer


  End Try
  begin catch
  
    set @Info = ERROR_MESSAGE() + ' (ExportSecur)'
    raiserror(@Info, 11, 1) 

  end catch

End -- yExport.ExportSecur
GO
if objectpropertyEx(object_id('Export.ExportDb'), 'isProcedure') = 1 
  Drop proc Export.ExportDb
GO
Create proc Export.ExportDb
  @dbName sysname 
, @collation sysname = NULL  
, @stopOnError Int = 1  
, @jobName sysname
as
Begin
  Set nocount on
  declare @rc int
  declare @Info nvarchar(max)
  declare @jobNo Int
  
  Select 'Look at messages TAB, to see work progress messages' as ReadThisPlease

  Declare @sql nvarchar(max)

  Set @jobName = 'Export data from '+@dbName+' to '+@dbName+'_Export'
  Print '===================================================='
  Print @jobName
  Print '===================================================='
  Begin try

  Exec yExecNLog.AddJobEntry
    @jobName = @jobName
  , @jobNo = @jobNo output  

  Exec @rc = yExport.CreateExportDatabase @dbname, @collation, @stopOnError, @jobNo
    
  If @rc = 0 
  Begin
    Exec yExport.ExportData @dbName, @stopOnError, @jobNo
    Exec yExport.ExportCode @dbName, @stopOnError, @jobNo
    Exec yExport.ExportSecur @dbName, @stopOnError, @jobNo 
  End
  
  End try
  Begin Catch
     set @Info = error_message()
     raiserror (@Info ,11,1)
  End Catch

end -- Export.ExportDb
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUtl.SqlModuleCopy'
GO

Create procedure yUtl.SqlModuleCopy
  @SourceDb sysname
, @TargetDb sysname = NULL
, @ObjectPropertyEx sysname = NULL  -- isExecuted, isProcedure, isFunction, isTrigger, ExecIsInsertTrigger, ....  
                                    -- see T-SQL OBJECTPROPERTYEX function for all parameters
, @SourceSchema sysname
, @TargetSchema sysname = NULL
, @SourceName sysname
, @TargetName sysname = NULL
As
Begin

  Declare @ObjectDef nvarchar(max)
  Declare @sql nvarchar(max)
  Declare @Info nvarchar(max)
  
  Set @TargetDb = ISNULL(@targetDb, @SourceDb)
  Set @TargetSchema = ISNULL(@targetSchema, @SourceSchema)
  Set @TargetName = ISNULL(@TargetName, @SourceName)
  
  Set @sql = 
  '
  use [<SourceDb>]; 
  Select @ObjectDef = M.[definition]
  From 
    sys.sql_modules M
  Where Object_id = Object_id(@SourceSchema+"."+@SourceName)
    And (@ObjectPropertyEx is NULL Or Objectpropertyex(Object_id, @ObjectPropertyEx)=1)
  print @SourceSchema+"."+@Sourcename  
  '
  Set @sql = replace(@sql, '<SourceDb>', @SourceDb)
  Set @sql = replace(@sql, '"', '''')
  
  Exec sp_executeSql 
    @sql
  , N'@SourceDb sysname
  , @SourceSchema sysname
  , @SourceName sysname
  , @ObjectPropertyEx sysname
  , @ObjectDef nvarchar(max) Output
  '
  , @SourceDb = @SourceDb
  , @SourceSchema = @SourceSchema
  , @Sourcename = @SourceName
  , @ObjectPropertyEx = @ObjectPropertyEx
  , @ObjectDef = @ObjectDef Output

  Set @sql = 
  '
  use [<TargetDb>]; 
  Exec YourSqlDba.f$.DropObj "[<TargetDb>].<TargetSchema>.<TargetName>"
  If Schema_id("<TargetSchema>") is NULL exec("Create schema <TargetSchema> authorization dbo;")
  Exec Sp_ExecuteSql @ObjectDef
  '
  Set @sql = replace(@sql, '<TargetDb>', @TargetDb)
  Set @sql = replace(@sql, '<TargetSchema>', @TargetSchema)
  Set @sql = replace(@sql, '<TargetName>', @TargetName)
  Set @sql = replace(@sql, '"', '''')
  
  Exec sp_executeSql @sql, N'@ObjectDef nvarchar(max)', @ObjectDef

End -- yUtl.SqlModuleCopy
go

--exec yUtl.SqlModuleCopy 
--  @SourceDb = 'yoursqldba'
--, @TargetDb = 'achat'
--, @SourceSchema = 'yUpgrade'
--, @sourcename = 'UpgradeFulltextCatalogsFromSql2005'
go
If Db_name() <> 'YourSqlDba' Use YourSqlDba
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yMirroring.DatabaseRecovery'
GO

Create procedure yMirroring.DatabaseRecovery
  @DbName sysname
As
Begin
 Declare @sql nvarchar(max)
 
 Set @sql = 'RESTORE DATABASE [<db>] WITH RECOVERY, REPLACE' 
 
 Set @sql = REPLACE(@sql, '<db>', @DbName)
 print @sql
 Exec(@sql)

End -- yMirroring.DatabaseRecovery
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Mirroring.DoRecovery'
GO

Create procedure Mirroring.DoRecovery
  @IncDb nVARCHAR(max) = '' 
, @ExcDb nVARCHAR(max) = '' 
As
Begin
 Declare @sql nvarchar(max)
 Declare @dbname sysname
 Declare @err nvarchar(max) 
 Set @err = ''
 
 Set NOCOUNT ON
 
  -- The function udf_YourSQLDba_ApplyFilterDb apply filter parameters on this list 
  Create table #Db
  (
    DbName sysname primary key clustered 
  , ErrorMsg nvarchar(max) default 'This is the database state before before putting it ''ONLINE''.'
  )
  Insert into #Db (DbName)
  Select X.DbName
  from 
    yUtl.YourSQLDba_ApplyFilterDb (@IncDb, @ExcDb) X
    Left Join
    master.sys.databases D
    On X.DbName = D.name Collate Latin1_general_ci_ai
  
  -- Exclude non-RESTORING databases
  Delete Db
  From #Db Db
  Where Exists(
                Select * 
                From sys.databases d 
                Where d.name = db.DbName 
                  and DatabasepropertyEx(d.name, 'Status') <> 'RESTORING'
              )

  -- For each database to process
  Set @dbname = ''
  
  While 1=1
  Begin
  
    Select Top 1 
      @DbName=DbName
    From #Db
    Where DbName > @dbname
    Order By DbName
    
    If @@rowcount = 0 break

    -- Switch the database from state "restoring" to available and recovered
    Set @sql = 'RESTORE DATABASE [<db>] WITH RECOVERY' 

    Set @sql = REPLACE(@sql, '<db>', @DbName)
    Print ''
    Print '> ' + @sql
    
    Begin Try  
      Exec sp_executeSql @sql
    End Try
    Begin Catch
      Set @err = ERROR_MESSAGE()
      Print ''
      Print 'Error. The database '''+ @DbName +''' has not changed to ''ONLINE''.   Msg: ' + @err
      
      Update Db 
      Set ErrorMsg = 'Msg: ' + @err
      From
        #Db Db
      Where Db.DbName = @DbName
           
    End Catch
     
  End --While 1=1 (DB list)

  -- Show results status for the selected databases
  Update Db 
  Set ErrorMsg = Case  
                   When X.name Is Not Null Then 'The database is now ''ONLINE''.' 
                   Else 'Error. The database has not changed to ''ONLINE''.  ' + ErrorMsg
                 End 
  From
    #Db Db
    Left Join
    master.sys.databases X
    On Db.DbName = X.name Collate Latin1_general_ci_ai
     And X.state_desc = 'ONLINE'      
  
  Select 
    DbName
  , ErrorMsg As N'Results ………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………………'
  From #Db
   
End -- Mirroring.DoRecovery
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'yUpgrade.UpgradeFulltextCatalogsFromSql2005'
GO

Create Procedure yUpgrade.UpgradeFulltextCatalogsFromSql2005
As
Begin
  declare @sql nvarchar(max)
  declare @colspec nvarchar(max)
  declare @object_id int
  declare @name sysname
  declare @CatalogName sysname
  declare @IndexName sysname
  declare @is_accent_sensitivity_on bit
  declare @Colname sysname
  declare @TypeColname sysname
  declare @language_id int
  declare @UniqueIndexName sysname
  declare @FileSize int
  declare @PhysicalPath nvarchar(max)

  Set NOCOUNT ON
  
  -- **************************************************************
  -- Conserver les définition d'index pour les recréer plus tard
  -- **************************************************************
  Select 
    Case 
      When c.name = 'eg_files_catalog' Then 'eg_files_catalog'        -- EDU_GROUPE
      When c.name like '%FILES[_]CATALOG' Then 'GED_FILES_CATALOG'    -- Clé de Voute
      When c.name like '%[_]CATALOG' Then 'GED_CATALOG'               -- Clé de Voute
      Else c.name
    End as CatalogName  
  , is_accent_sensitivity_on
  , FULLTEXTCATALOGPROPERTY(c.name,'IndexSize') as Size 
  , ui.name as UniqueIndexName
  , object_name(i.object_id) as IndexName
  , c1.name As ColName
  , c2.name as TypeColName
  , ic.language_id 
  Into #FulltextIndexes
  From 
    sys.fulltext_catalogs c

    Join
    sys.fulltext_indexes i
    On i.fulltext_catalog_id = c.fulltext_catalog_id
    
    join
    sys.indexes ui
    On   ui.object_id = i.object_id
     And ui.index_id = i.unique_index_id

    join
    sys.fulltext_index_columns ic
    On ic.object_id = i.object_id
    
    join
    sys.columns c1
    On c1.object_id = ic.object_id
     And c1.column_id = ic.column_id
       
    left join
    sys.columns c2
    On c2.object_id = ic.object_id
     And c2.column_id = ic.type_column_id 
     
  -- ************************************************************
  -- Si aucun index plein texte trouver on a plus rien à faire
  -- ************************************************************
  If Not Exists( Select * From #FulltextIndexes)
  Begin
      Print 'Aucun index plein texte non-migré trouvé'
      return
  End

  -- **********************************************************
  -- Supprimer tous ce qui se rapporte aux indexes Fulltext
  --  . Indexes
  --  . Catalogues
  --  . Fichiers *.ndf
  --  . FileGroup
  -- **********************************************************

  -- ***************************************
  -- Supprimer tous les index plein texte
  -- ***************************************
  Set @object_id = 0

  while 1=1
  Begin
    
    Select Top 1 @object_id = object_id
    From sys.fulltext_indexes
    Where object_id > @object_id
    Order by object_id
    
    If @@ROWCOUNT = 0
      break
      
    Set @sql = 'DROP FULLTEXT INDEX ON [<tn>]'
    Set @sql = Replace(@sql, '<tn>', object_name(@object_id) )
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
      
  End


  -- *******************************
  -- Supprimer tous les catalogue
  -- *******************************
  Set @name = ''

  while 1=1
  Begin
    
    Select Top 1 @name = name
    From sys.fulltext_catalogs
    Where name > @name
    Order by name
    
    If @@ROWCOUNT = 0
      break
      
    Set @sql = 'DROP FULLTEXT CATALOG [<cn>]'
    Set @sql = Replace(@sql, '<cn>', @name )
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
      
  End


  -- ******************************************************************************
  -- Supprimer tous les fichiers de donnée qui contiennent des index plein texte 
  -- ******************************************************************************
  Set @name = ''

  while 1=1
  Begin
    
    Select Top 1 @name = name
    From sys.database_files 
    Where name like 'ftrow_%'
      And name > @name
    Order by name
    
    If @@ROWCOUNT = 0
      break
      
    Set @sql = 'ALTER DATABASE [<db>] REMOVE FILE [<fn>]'
    Set @sql = Replace(@sql, '<db>', db_name())
    Set @sql = Replace(@sql, '<fn>', @name )
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
      
  End


  -- **********************************************************************************
  -- Supprimer tous les FileGroup qui contenait des fichier d'indexation plein texte
  -- **********************************************************************************
  Set @name = ''

  while 1=1
  Begin
    
    Select Top 1 @name = name
    From sys.data_spaces 
    Where name like 'ftfg_%'
      And name > @name
    Order by name
    
    If @@ROWCOUNT = 0
      break
      
    Set @sql = 'ALTER DATABASE [<db>] REMOVE FILEGROUP [<fgn>]'
    Set @sql = Replace(@sql, '<db>', db_name())
    Set @sql = Replace(@sql, '<fgn>', @name )
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
      
  End

  -- **************************************************************
  -- Créer un FileGroup pour le ou les catalogues s'il n'existe pas déjà
  -- **************************************************************
  If Exists (Select * From #FulltextIndexes)
   And Not Exists (Select * From sys.filegroups where name = 'CATALOGS')
  Begin
    Set @sql = 'ALTER DATABASE [<db>] ADD FILEGROUP [CATALOGS]'
    Set @sql = Replace(@sql, '<db>', db_name())
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
  End

  -- **************************************************************
  -- Ajouter un fichier de données dans le FILEGROUP Catalogs
  -- **************************************************************
  If Not Exists (Select * 
                 From 
                   sys.filegroups fg
                   join
                   sys.database_files dbf
                   On dbf.data_space_id = fg.data_space_id
                 Where fg.name = 'CATALOGS'
                   And dbf.state_desc = 'ONLINE')
  Begin               
    Select @FileSize = SUM(Size) * 1.25
    From
      (
      Select Distinct CatalogName, Size
      From #FulltextIndexes
      ) X
      
    Set @FileSize = Case When @FileSize = 0 Then 50 Else @FileSize End
      
    Select @PhysicalPath = Left(physical_name, Len(physical_name) - CharIndex('\', Reverse(physical_name)) + 1)
    From 
      sys.database_files
    Where file_id = 1

    Set @sql = 'ALTER DATABASE [<db>] ADD FILE (NAME="<db>_CATALOGS", FILENAME="<filepath><db>_CATALOGS.ndf", SIZE=<size>, FILEGROWTH= 10 %) TO FILEGROUP [CATALOGS]'
    Set @sql = Replace(@sql, '<db>', db_name())
    Set @sql = Replace(@sql, '<filepath>', @PhysicalPath)
    Set @sql = Replace(@sql, '<size>', convert(nvarchar(25), @FileSize))
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
  End

  -- **************************************************************
  -- Recréer les catalogues
  -- **************************************************************
  Set @CatalogName = ''

  while 1=1
  Begin
    
    Select Distinct Top 1 @CatalogName = CatalogName, @is_accent_sensitivity_on = is_accent_sensitivity_on
    From #FulltextIndexes 
    Where CatalogName > @CatalogName
    Order by CatalogName
    
    If @@ROWCOUNT = 0
      break
      
    Set @sql = 'CREATE FULLTEXT CATALOG [<name>] WITH ACCENT_SENSITIVITY = <AS>'
    Set @sql = Replace(@sql, '<name>', @CatalogName )  
    Set @sql = Replace(@sql, '<AS>', Case @is_accent_sensitivity_on When 1 Then 'ON' Else 'OFF' End )
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
      
  End

  -- **************************************************************
  -- Recréer les indexes fulltext
  -- **************************************************************

  Set @IndexName = ''

  while 1=1
  Begin
    
    Select Distinct Top 1 @IndexName = IndexName, @UniqueIndexName = UniqueIndexName, @CatalogName = CatalogName
    From #FulltextIndexes 
    Where IndexName > @IndexName
    Order by IndexName
    
    If @@ROWCOUNT = 0
      break

    Set @sql = 
    '
    CREATE FULLTEXT INDEX ON [<tn>] 
    (
    <colspec>
    )
    KEY INDEX [<indexname>]
    ON ([<catalog>], FILEGROUP CATALOGS)
    WITH CHANGE_TRACKING = AUTO 
    '
      
    Set @ColName = ''
    
    while 1=1
    Begin
      Select Top 1 @ColName = ColName, @TypeColName = TypeColName, @language_id = language_id
      From #FulltextIndexes 
      Where IndexName = @IndexName
        And ColName > @ColName
      Order by ColName
      
      If @@ROWCOUNT = 0
      break
      
      Set @colspec = '<cn> <TypeColumn> LANGUAGE <language_id>'
      Set @colspec = Replace(@colspec, '<cn>', @ColName)
      Set @colspec = Replace(@colspec, '<TypeColumn>', Case When @TypeColName Is Null Then '' Else 'TYPE COLUMN ' + @TypeColName End)
      Set @colspec = Replace(@colspec, '<language_id>', @language_id)
          
      Set @colspec = @colspec + ',<colspec>'
      Set @sql = Replace(@sql, '<colspec>', @colspec)

    End

    Set @sql = Replace(@sql, ',<colspec>', '')

      
    Set @sql = Replace(@sql, '<tn>', @IndexName )  
    Set @sql = Replace(@sql, '<indexname>', @UniqueIndexName )    
    Set @sql = Replace(@sql, '<catalog>', @CatalogName )  
    Set @sql = Replace(@sql, '"', '''')
    Print @sql
    Exec(@sql)
      
  End

End -- yUpgrade.UpgradeFulltextCatalogsFromSql2005
GO

If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Upgrade.MakeDbCompatibleToTarget'
GO

Create procedure Upgrade.MakeDbCompatibleToTarget
  @DbName sysname
As
Begin
  Declare @sql nvarchar(max)
 
  -- Put the database in multi-user
  Set @sql = 'ALTER DATABASE [<db>] SET MULTI_USER WITH ROLLBACK IMMEDIATE' 
 
  Set @sql = REPLACE(@sql, '<db>', @DbName)
  print @sql
  Exec(@sql)


  Declare @dbCompatLevel Int
  select @dbCompatLevel = compatibility_level From Sys.databases Where name = @DbName

  Select @sql = 'ALTER DATABASE[<db>] SET COMPATIBILITY_LEVEL = ' + convert(nvarchar, yInstall.SqlVersionNumber ())
  Set @sql = REPLACE(@sql, '<db>', @DbName)
  print @sql
  Exec(@sql)

  -- the db is above SQL2005 or target server is SQL2005, no need to upgrade fulltext catalogs
  If @dbCompatLevel > 90 Or yInstall.SqlVersionNumber () = 90
    Return
 
  -- Normalize full text catalogs
  Exec yUtl.SqlModuleCopy 
    @SourceDb = 'yoursqldba'
  , @TargetDb = @DbName
  , @SourceSchema = 'yUpgrade'
  , @sourcename = 'UpgradeFulltextCatalogsFromSql2005'
 
  Set @sql = 'Exec [<db>].yUpgrade.UpgradeFulltextCatalogsFromSql2005' 
  Set @sql = REPLACE(@sql, '<db>', @DbName)
  print @sql
  Exec(@sql)
 
  Set @sql = 'use [<db>] Drop Procedure yUpgrade.UpgradeFulltextCatalogsFromSql2005' 
  Set @sql = REPLACE(@sql, '<db>', @DbName)
  print @sql
  Exec(@sql)

  Set @sql = 'use [<db>] Drop Schema yUpgrade' 
  Set @sql = REPLACE(@sql, '<db>', @DbName)
  print @sql
  Exec(@sql)

End -- Upgrade.MakeDbCompatibleToTarget
GO
--------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
Exec f$.DropObj 'Mirroring.Failover'
GO
------------------------------------------------------------------------------------------
If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
------------------------------------------------------------------------------------------
CREATE procedure [Mirroring].[Failover]
  @IncDb nVARCHAR(max) = '' 
, @ExcDb nVARCHAR(max) = '' 
, @Simulation int = 0
As
Begin
  Declare @sql nvarchar(max)
  Declare @MirrorServer sysname
  Declare @dbname sysname
  Declare @dbOwner sysname
  Declare @FullRecoveryMode int
  Declare @lastLogBkpFile nvarchar(512)
  Declare @lastFullBkpFile nvarchar(512)
  Declare @lastDiffBkpFile nvarchar(512)
  Declare @fileName nvarchar(512)
  Declare @bkpTyp nchar(1)
  Declare @OverwriteBackup int
  Declare @ListBDMigre nvarchar(max)
  Declare @TargetProductVersion Int
  Declare @ReplaceSrcBkpPathToMatchingMirrorPath nvarchar(max)
  Declare @ReplacePathsInDbFilenames nvarchar(max)
  Declare @maxSeverity int
  Declare @msgs Nvarchar(max)

  Set NOCOUNT ON

   -- The function udf_YourSQLDba_ApplyFilterDb apply filter parameters on this list 
  Create table #Db
  (
    DbName sysname primary key clustered 
  , DbOwner sysname
  , FullRecoveryMode int -- If = 1 log backup allowed
  , lastLogBkpFile nvarchar(512) null
  , lastFullBkpFile nvarchar(512) null
  , lastDiffBkpFile nvarchar(512) null
  , MirrorServer sysname null
  , ReplaceSrcBkpPathToMatchingMirrorPath nvarchar(max)
  , ReplacePathsInDbFilenames nvarchar(max)
  , ErrorMsg nvarchar(max) default 'Succès'
  )
  Insert into #Db (DbName, DbOwner, FullRecoveryMode, lastLogBkpFile, lastFullBkpFile, lastDiffBkpFile, MirrorServer, ReplaceSrcBkpPathToMatchingMirrorPath, ReplacePathsInDbFilenames)
  Select 
    X.DbName
  , X.DbOwner
  , X.FullRecoveryMode 
  , L.lastLogBkpFile
  , L.lastFullBkpFile
  , L.lastDiffBkpFile
  , L.MirrorServer
  , L.ReplaceSrcBkpPathToMatchingMirrorPath
  , L.ReplacePathsInDbFilenames
  from 
    yUtl.YourSQLDba_ApplyFilterDb (@IncDb, @ExcDb) X
    join
    Maint.JobLastBkpLocations L
    On L.dbName = X.DbName
  
  -- Remove Snapshot databases
  Delete Db
  From #Db Db
  Where Exists(Select * 
               From sys.databases d 
               Where d.name = db.DbName 
                 and source_database_Id is not null
              )


  If @Simulation = 0
  Begin
    -- Synchroniser Logins on all «MirrorServer»  
    Set @MirrorServer = ''
    
    While 1=1
    Begin
      Select DISTINCT Top 1 @MirrorServer=MirrorServer
      From #Db
      Where MirrorServer > @MirrorServer
      Order by MirrorServer
      
      If @@rowcount = 0 break
      
      Print ''
      Print ''
      Print '-- *************************************************'
      Print '-- Synchronisation des logins sur ' + @MirrorServer
      Print '-- *************************************************'
    
      Exec yMirroring.LaunchLoginSync @MirrorServer = @MirrorServer
    End  
 

  --for each BD to process
  Set @dbname = ''
  
  While 1=1
  Begin
  
    Select Top 1 
      @dbname=DbName
    , @dbOwner=DbOwner
    , @FullRecoveryMode=FullRecoveryMode
    , @lastLogBkpFile=lastLogBkpFile
    , @lastFullBkpFile=lastFullBkpFile
    , @lastDiffBkpFile=lastDiffBkpFile
    , @MirrorServer=MirrorServer
    , @ReplaceSrcBkpPathToMatchingMirrorPath=Isnull(ReplaceSrcBkpPathToMatchingMirrorPath, '')
    , @ReplacePathsInDbFilenames=IsNull(ReplacePathsInDbFilenames, '')
    From #Db
    Where DbName > @dbname
    Order By DbName
    
    If @@rowcount = 0 break

    -- Assert that the database is online    
    If DatabasepropertyEx(@dbname, 'Status') <> 'Online'
    Begin
      Update #Db Set ErrorMsg = 'Database  ['+@dbname+'] is not ONLINE and cannot be processed' 
      Where DbName = @dbname
      continue
    End
    
    -- Assert that the Database is setup for mirroring 
    If @MirrorServer = ''
    Begin
      Update #Db 
      Set ErrorMsg = 'Database ['+@dbname+'] is not mirrored and won''t be failed over' 
      Where DbName = @dbname
      continue  
    End

    -- Assert that the mirror server is as least the same version or higher than the source server
    Declare @DbStatus sysname
    Set @sql = 'SELECT @DbStatus=Version FROM openquery ([<MirrorServer>], "SELECT Convert(sysname, DatabasepropertyEx(@dbname, ""Status"")) as DbStatus")'
    Set @sql = REPLACE(@sql, '<MirrorServer>', @MirrorServer)  
    Set @sql = REPLACE(@sql, '"', '''')
    Exec sp_executesql @sql, N'@DbStatus Int OUTPUT', @DbStatus=@DbStatus OUTPUT

    If @DbStatus IS NOT NULL And @DbStatus <> 'RESTORING'
    Begin 
      Update #Db 
      Set ErrorMsg = 'Database ['+@dbname+'] is not in recovery state and won''t be failed over' 
      Where DbName = @dbname
      Continue
    End
    
    -- Assert that the mirror server is as least the same version or higher than the source server
    Set @sql = 'SELECT @TargetProductVersion=Version FROM openquery ([<MirrorServer>], "SELECT YourSqlDba.yInstall.SqlVersionNumber() AS [Version]")'
    Set @sql = REPLACE(@sql, '<MirrorServer>', @MirrorServer)  
    Set @sql = REPLACE(@sql, '"', '''')
    Exec sp_executesql @sql, N'@TargetProductVersion Int OUTPUT', @TargetProductVersion=@TargetProductVersion OUTPUT

    If @TargetProductVersion < yInstall.SqlVersionNumber ()
    Begin
      Update #Db 
      Set ErrorMsg = 'The target server ['+@MirrorServer+'] must be a version equal or above the source server' 
      Where DbName = @dbname
      continue  
    End    
    
    -- Signal that databases in simple recovery mode are going to backuped again, and that it will
    -- make maintenance longer
    If @FullRecoveryMode = 0
    Begin
      Update #Db 
      Set ErrorMsg = 'Database ['+@dbname+'] is in simple recovery.  A differential backup will be performed making upgrade possibly a bit slower.' 
      Where DbName = @dbname
      -- 
    End
            
    If @Simulation = 0
    Begin
      Print ''
      Print '-- *************************************************'
      Print '-- Processing database ' + @dbname
      Print '-- *************************************************'

      -- efficient kill for all connections
      Set @sql = 
      '
      ALTER DATABASE [<dbname>] SET OFFLINE WITH ROLLBACK IMMEDIATE
      ALTER DATABASE [<dbname>] SET ONLINE 
      ' 
     
      Set @sql = REPLACE(@sql, '<dbname>', @dbname)
      Print ''
      print '> ' + @sql
      Exec(@sql)
      
      -- If the database is in full recovery mode, proceed to a last log backup
      -- oterwise a differential backup will be necessary
      If @FullRecoveryMode=1
      Begin
        -- Do the last log backup
        Set @bkpTyp = 'L'
        Set @fileName = @lastLogBkpFile
        Set @OverwriteBackup = 0
      End
      Else
      Begin
        -- Do a differential backup
        Set @bkpTyp = 'D'
        If @lastDiffBkpFile IS NOT NULL
          Set @fileName = @lastFullBkpFile -- overwrite existing differential backup
        Else
        Begin
          -- extract backup location from last full backup location to build the new filename
          Set @fileName = reverse(@lastFullBkpFile)
          declare @pathBkp nvarchar(512) = Reverse(Stuff(@filename, 1, charindex('\', @filename), ''))
          declare @language sysname
          Exec yInstall.InstallationLanguage @Language output
          -- with differential backup timestamp naming is not useful in a failover context
          Select @filename = YourSqlDba.yMaint.MakeBackupFileName (@dbname, 'D', @pathBkp, @Language, 'Bak', 0);
        End  
        Set @OverwriteBackup = 1
      End
      
      Set @sql = yMaint.MakeBackupCmd( @dbname, @bkpTyp, @fileName, @OverwriteBackup, Null)
      Exec(@sql)     
         
      -- Restore backup to mirroir
      Set @sql = 
      '
      Exec [<MirrorServer>].YourSqlDba.yMirroring.DoRestore 
         @BackupType="<BackupType>"
       , @Filename="<Filename>"
       , @DbName="<DbName>"
       , @ReplaceSrcBkpPathToMatchingMirrorPath = "<ReplaceSrcBkpPathToMatchingMirrorPath>"
       , @ReplacePathsInDbFilenames = "<ReplacePathsInDbFilenames>"'
      Set @sql = REPLACE(@sql, '<BackupType>', @bkpTyp)
      Set @sql = REPLACE(@sql, '<Filename>', @fileName)
      Set @sql = REPLACE(@sql, '<DbName>', @DbName)
      Set @sql = REPLACE(@sql, '<MirrorServer>', @MirrorServer)  
      Set @sql = REPLACE(@sql, '<ReplaceSrcBkpPathToMatchingMirrorPath>', @ReplaceSrcBkpPathToMatchingMirrorPath)  
      Set @sql = REPLACE(@sql, '<ReplacePathsInDbFilenames>', @ReplacePathsInDbFilenames)  

      Set @sql = REPLACE(@sql, '"', '''')

      Exec yExecNLog.ExecWithProfilerTrace @sql, @MaxSeverity output, @Msgs output
      If @maxSeverity > 10 
      Begin
        Raiserror (N'Mirroring.Failover error %s: %s %s', 11, 1, @@SERVERNAME, @Sql, @Msgs)    
        Return (1)
      End

      Set @sql = 'Exec ("Alter Authorization On database::[<DbName>] To [<DbOwner>]") at [<MirrorServer>]'
      Set @sql = REPLACE(@sql, '<DbName>', @DbName)
      Set @sql = REPLACE(@sql, '<DbOwner>', @DbOwner)  
      Set @sql = REPLACE(@sql, '<MirrorServer>', @MirrorServer)  
      Set @sql = REPLACE(@sql, '"', '''')

      Exec yExecNLog.ExecWithProfilerTrace @sql, @MaxSeverity output, @Msgs output
      If @maxSeverity > 10 
      Begin
        Raiserror (N'Mirroring.Failover error %s: %s %s', 11, 1, @@SERVERNAME, @Sql, @Msgs)    
        Return (1)
      End

      -- Set BD in Multi-User before to go offline
      -- it is complicated to come back multi-user when we go from offline and single_user 
      Set @sql = 'ALTER DATABASE [<dbname>] SET MULTI_USER WITH ROLLBACK IMMEDIATE' 
     
      Set @sql = REPLACE(@sql, '<dbname>', @dbname)
      Print ''
      print '> ' + @sql
      Exec(@sql)
      
      -- Put the database Offline, so no more updates are possible to the old Db
      Set @sql = 'ALTER DATABASE [<dbname>] SET OFFLINE WITH ROLLBACK IMMEDIATE' 
     
      Set @sql = REPLACE(@sql, '<dbname>', @DbName)
      Print ''
      print '> ' + @sql
      Exec(@sql)
      
      -- Switch the database on remote server, from state "restoring" to available and recovered
      Set @sql = 'Exec [<MirrorServer>].YourSqlDba.yMirroring.DatabaseRecovery @DbName="<DbName>"'
      
      Set @sql = REPLACE(@sql, '<DbName>', @DbName)
      Set @sql = REPLACE(@sql, '<MirrorServer>', @MirrorServer)  
      Set @sql = REPLACE(@sql, '"', '''')
      Print ''
      print '> ' + @sql
      Exec(@sql) 
      
      -- Finalize the migration
      Set @sql = 'Exec [<MirrorServer>].YourSqlDba.Upgrade.MakeDbCompatibleToTarget @DbName="<DbName>"'
      
      Set @sql = REPLACE(@sql, '<DbName>', @DbName)
      Set @sql = REPLACE(@sql, '<MirrorServer>', @MirrorServer)  
      Set @sql = REPLACE(@sql, '"', '''')
      Print ''
      print '> ' + @sql
      Exec(@sql) 

      Set @sql = 
      '
      Update Db 
      Set ErrorMsg = Case  
                       When X.name Is Not Null Then "Success" 
                       Else "Unexpected error. Compatibility level should""ve been set to be equal to server version. Check ShowHistoryErrors to get some details about this problem" 
                     End 
      From
        #Db Db
        Left Join
        [<mirrorserver>].master.sys.databases X
        On Db.DbName = X.name Collate Latin1_general_ci_ai
         And X.compatibility_level = <compatLevel>
         And X.user_access_desc = "MULTI_USER"
         And X.state_desc = "ONLINE"      
      Where Db.DbName = "<dbname>" 
      '
      Set @sql = REPLACE(@sql, '<dbname>', @DbName)
      Set @sql = REPLACE(@sql, '<mirrorserver>', @MirrorServer)  
      Set @sql = REPLACE(@sql, '<compatLevel>', convert(nvarchar, @TargetProductVersion)  )
      Set @sql = REPLACE(@sql, '"', '''')
      Print ''
      print '> ' + @sql
      Exec(@sql)                  

    End --If @Simulation = 0       
    
  End --While 1=1 (liste des BD)
  
  
  End --If @Simulation = 0
  
  -- Show maintenance status for all databases
  Select DbName, ErrorMsg As Statut
  From #Db
   
End -- Mirroring.Failover
go

If Db_name() <> 'YourSqlDba' Use YourSqlDba
GO
If Exists(select * from sys.symmetric_keys Where name = '##MS_DatabaseMasterKey##') Drop master Key 
IF NOT Exists (Select * From sys.databases Where name ='YourSQLDba' And is_master_key_encrypted_by_server=1)
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'Aa$1YourSQLDba123456789012345678901234567890'
GO

ALTER DATABASE YourSQLDba SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
GO

ALTER DATABASE YourSQLDba SET NEW_BROKER WITH ROLLBACK IMMEDIATE;
GO

IF EXISTS (SELECT * FROM sys.services WHERE name = N'//YourSQLDba/MirrorRestore/TargetService')
     DROP SERVICE [//YourSQLDba/MirrorRestore/TargetService];
GO

IF EXISTS (SELECT * FROM sys.service_queues WHERE name = N'YourSQLDbaTargetQueueMirrorRestore')
     DROP QUEUE YourSQLDbaTargetQueueMirrorRestore;
GO

IF EXISTS (SELECT * FROM sys.services WHERE name = N'//YourSQLDba/MirrorRestore/InitiatorService')
     DROP SERVICE [//YourSQLDba/MirrorRestore/InitiatorService];
GO
  
IF EXISTS (SELECT * FROM sys.service_queues
           WHERE name = N'YourSQLDbaInitiatorQueueMirrorRestore')
     DROP QUEUE YourSQLDbaInitiatorQueueMirrorRestore;
GO

IF EXISTS (SELECT * FROM sys.service_contracts
           WHERE name =
           N'//YourSQLDba/MirrorRestore/Contract')
     DROP CONTRACT
     [//YourSQLDba/MirrorRestore/Contract];
GO

IF EXISTS (SELECT * FROM sys.service_message_types
           WHERE name =
           N'//YourSQLDba/MirrorRestore/Request')
     DROP MESSAGE TYPE
     [//YourSQLDba/MirrorRestore/Request];
GO

IF EXISTS (SELECT * FROM sys.service_message_types
           WHERE name =
           N'//YourSQLDba/MirrorRestore/Reply')
     DROP MESSAGE TYPE
     [//YourSQLDba/MirrorRestore/Reply];
GO

IF EXISTS (SELECT * FROM sys.service_message_types
           WHERE name =
           N'//YourSQLDba/MirrorRestore/End')
     DROP MESSAGE TYPE
     [//YourSQLDba/MirrorRestore/End];
GO

CREATE MESSAGE TYPE
       [//YourSQLDba/MirrorRestore/Request]
       VALIDATION = WELL_FORMED_XML;
GO

CREATE MESSAGE TYPE
       [//YourSQLDba/MirrorRestore/Reply]
       VALIDATION = WELL_FORMED_XML;
GO

CREATE MESSAGE TYPE
       [//YourSQLDba/MirrorRestore/End]
       VALIDATION = NONE
GO

CREATE CONTRACT [//YourSQLDba/MirrorRestore/Contract]
      ([//YourSQLDba/MirrorRestore/Request]
       SENT BY INITIATOR,
       [//YourSQLDba/MirrorRestore/End]
       SENT BY INITIATOR,
       [//YourSQLDba/MirrorRestore/Reply]
       SENT BY TARGET
      );
GO

CREATE QUEUE YourSQLDbaTargetQueueMirrorRestore
  WITH 
    STATUS  = ON
  , ACTIVATION (
      PROCEDURE_NAME = yMirroring.Broker_AutoActivated_LaunchRestoreToMirrorCmd,
      MAX_QUEUE_READERS = 1,  -- Very important to preserve the restore sequence of backups
      EXECUTE AS SELF );
GO

CREATE QUEUE YourSQLDbaInitiatorQueueMirrorRestore
  WITH
    STATUS  = ON
GO

CREATE SERVICE
       [//YourSQLDba/MirrorRestore/TargetService]
       ON QUEUE YourSQLDbaTargetQueueMirrorRestore
       ([//YourSQLDba/MirrorRestore/Contract]);
GO

CREATE SERVICE
       [//YourSQLDba/MirrorRestore/InitiatorService]
       ON QUEUE YourSQLDbaInitiatorQueueMirrorRestore;
GO 

-- the sole purpose of these synonyms is to avoid
-- breaking scripts that could used the previous name with dbo. schema
-- Ia also ease calling of procedures not prefixed by the schema maint.
If OBJECT_ID ('dbo.DiagDbMail') IS NULL 
  create synonym dbo.DiagDbMail For Maint.DiagDbMail
If OBJECT_ID ('dbo.BringBackOnlineAllOfflineDb') IS NULL 
  create synonym dbo.BringBackOnlineAllOfflineDb For Maint.BringBackOnlineAllOfflineDb
If OBJECT_ID ('dbo.DeleteOldBackups') IS NULL 
  create synonym dbo.DeleteOldBackups For Maint.DeleteOldBackups
If OBJECT_ID ('dbo.YourSqlDba_DoMaint') IS NULL 
  create synonym dbo.YourSqlDba_DoMaint For Maint.YourSqlDba_DoMaint
If OBJECT_ID ('dbo.SaveDbOnNewFileSet') IS NULL 
  create synonym dbo.SaveDbOnNewFileSet For Maint.SaveDbOnNewFileSet
If OBJECT_ID ('dbo.SaveDbCopyOnly') IS NULL 
  create synonym dbo.SaveDbCopyOnly For Maint.SaveDbCopyOnly
If OBJECT_ID ('dbo.DuplicateDb') IS NULL 
  create synonym dbo.DuplicateDb For Maint.DuplicateDb
If OBJECT_ID ('dbo.DuplicateDbFromBackupHistory') IS NULL 
  create synonym dbo.DuplicateDbFromBackupHistory For Maint.DuplicateDbFromBackupHistory
If OBJECT_ID ('dbo.RestoreDb') IS NULL 
  create synonym dbo.RestoreDb For Maint.RestoreDb
If OBJECT_ID ('dbo.ShowHistory') IS NULL 
  create synonym dbo.ShowHistory For Maint.ShowHistory
If OBJECT_ID ('dbo.CreateNetworkDrives') IS NULL 
  create synonym dbo.CreateNetworkDrives For Maint.CreateNetworkDrives
If OBJECT_ID ('dbo.DisconnectNetworkDrive') IS NULL 
  create synonym dbo.DisconnectNetworkDrive For Maint.DisconnectNetworkDrive
If OBJECT_ID ('dbo.ListNetworkDrives') IS NULL 
  create synonym dbo.ListNetworkDrives For Maint.ListNetworkDrives
If OBJECT_ID ('dbo.PrepDbForMaintenanceMode') IS NULL 
  create synonym dbo.PrepDbForMaintenanceMode For Maint.PrepDbForMaintenanceMode
If OBJECT_ID ('dbo.RestoreDbAtStartOfMaintenanceMode') IS NULL 
  create synonym dbo.RestoreDbAtStartOfMaintenanceMode For Maint.RestoreDbAtStartOfMaintenanceMode
If OBJECT_ID ('dbo.ReturnDbToNormalUseFromMaintenanceMode') IS NULL 
  create synonym dbo.ReturnDbToNormalUseFromMaintenanceMode For Maint.ReturnDbToNormalUseFromMaintenanceMode
  
go
grant execute on dbo.SaveDbOnNewFileSet to guest
GO
grant execute on dbo.SaveDbCopyOnly to guest
GO
grant execute on dbo.DuplicateDb to guest
GO
grant execute on dbo.DuplicateDbFromBackupHistory to guest
GO
grant execute on dbo.RestoreDb to guest
GO
-- check YourSqlDba account access through mirror server, and correct it if necessary. If failure to do it send a e-mail
Exec yMirroring.CleanMirrorServerForMissingServerAndCheckServerAccessAsYourSqlDbaAccount 
GO
-- changing parameter name ConsecutiveDaysOfFailedBackupsToPutDbOffline to ConsecutiveFailedbackupsDaysToPutDbOffline


-- ==================================================================================
--  ** SAMPLE** SAMPLE** SAMPLE** SAMPLE** SAMPLE** SAMPLE** SAMPLE
--  ** CONFIG  of MAINTENANCE
-- ==================================================================================
--If Db_name() <> 'YourSqlDba' Use YourSqlDba
--Exec Install.InitialSetupOfYourSqlDba 
--  @FullBackupPath  = 'c:\iSql2005Backups'  -- full backup directory
--, @LogBackupPath = 'c:\iSql2005Backups'    -- log backup directory
--, @email = 'me@myDomain'       -- log maintenance 
--, @SmtpMailServer = 'myEmailServer'   -- email server which allow incoming smtp request from SQL Server
--, @ConsecutiveDaysOfFailedBackupsToPutDbOffline = 9999
-- ==================================================================================
--  ** End Of SAMPLE** ** End Of SAMPLE** ** End Of SAMPLE** 
-- ==================================================================================
GO

If Schema_id('utl') is NOT NULL drop schema utl
GO
Exec Install.PrintVersionInfo
