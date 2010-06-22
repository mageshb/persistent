{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE FlexibleContexts #-}
-- | A postgresql backend for persistent.
module Database.Persist.Postgresql
    ( PostgresqlReader
    , persistPostgresql
    , runPostgresql
    , withPostgresql
      -- * Re-exports
    , Connection
    , connectPostgreSQL
    , Int64
    , module Database.Persist.Helper
    , persist
    ) where

import Database.Persist (PersistValue (..))
import Database.Persist.Helper
import Database.Persist.GenericSql
import Control.Monad.Trans.Reader
import Language.Haskell.TH.Syntax hiding (lift)
import Control.Monad.IO.Class (MonadIO (..))
import Data.List (intercalate)
import "MonadCatchIO-transformers" Control.Monad.CatchIO
import qualified Database.HDBC as H
import Database.HDBC.PostgreSQL
import Data.Char (toLower)

-- | Generate data types and instances for the given entity definitions. Can
-- deal directly with the output of the 'persist' quasi-quoter.
persistPostgresql :: [EntityDef] -> Q [Dec]
persistPostgresql = fmap concat . mapM derivePersistPostgresqlReader

-- | A ReaderT monad transformer holding a postgresql database connection.
type PostgresqlReader = ReaderT Connection

-- | Handles opening and closing of the database connection automatically.
withPostgresql :: MonadCatchIO m => String -> (Connection -> m a) -> m a
withPostgresql s f =
    bracket (liftIO $ connectPostgreSQL s) (liftIO . H.disconnect) f

-- | Run a series of database actions within a single transactions. On any
-- exception, the transaction is rolled back.
runPostgresql :: MonadCatchIO m => PostgresqlReader m a -> Connection -> m a
runPostgresql r conn = do
    res <- onException (runReaderT r conn) $ liftIO (H.rollback conn)
    liftIO $ H.commit conn
    return res

withStmt :: MonadIO m
         => String
         -> [PersistValue]
         -> (RowPopper (PostgresqlReader m) -> PostgresqlReader m a)
         -> PostgresqlReader m a
withStmt sql vals f = do
    conn <- ask
    stmt <- liftIO $ H.prepare conn sql
    _ <- liftIO $ H.execute stmt $ map pToSql vals
    f $ liftIO $ (fmap . fmap) (map pFromSql) $ H.fetchRow stmt

execute :: MonadIO m => String -> [PersistValue] -> PostgresqlReader m ()
execute sql vals = do
    conn <- ask
    stmt <- liftIO $ H.prepare conn sql
    _ <- liftIO $ H.execute stmt $ map pToSql vals
    return ()

insert :: MonadIO m
       => String -> [String] -> [PersistValue] -> PostgresqlReader m Int64
insert t cols vals = do
    let sql = "INSERT INTO " ++ t ++
              "(" ++ intercalate "," cols ++
              ") VALUES(" ++
              intercalate "," (map (const "?") cols) ++ ") " ++
              "RETURNING id"
    withStmt sql vals $ \pop -> do
        Just [PersistInt64 i] <- pop
        return i

tableExists :: MonadIO m => String -> PostgresqlReader m Bool
tableExists t = do
    conn <- ask
    tables <- liftIO $ H.getTables conn
    return $ map toLower t `elem` tables

derivePersistPostgresqlReader :: EntityDef -> Q [Dec]
derivePersistPostgresqlReader t = do
    let wrap = ConT ''ReaderT `AppT` ConT ''Connection
    gs <- [|GenericSql withStmt execute insert tableExists "SERIAL UNIQUE"|]
    deriveGenericSql wrap gs t

pToSql :: PersistValue -> H.SqlValue
pToSql (PersistString s) = H.SqlString s
pToSql (PersistByteString bs) = H.SqlByteString bs
pToSql (PersistInt64 i) = H.SqlInt64 i
pToSql (PersistDouble d) = H.SqlDouble d
pToSql (PersistBool b) = H.SqlBool b
pToSql (PersistDay d) = H.SqlLocalDate d
pToSql (PersistTimeOfDay t) = H.SqlLocalTimeOfDay t
pToSql (PersistUTCTime t) = H.SqlUTCTime t
pToSql PersistNull = H.SqlNull

pFromSql :: H.SqlValue -> PersistValue
pFromSql (H.SqlString s) = PersistString s
pFromSql (H.SqlByteString bs) = PersistByteString bs
pFromSql (H.SqlWord32 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlWord64 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlInt32 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlInt64 i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlInteger i) = PersistInt64 $ fromIntegral i
pFromSql (H.SqlChar c) = PersistInt64 $ fromIntegral $ fromEnum c
pFromSql (H.SqlBool b) = PersistBool b
pFromSql (H.SqlDouble b) = PersistDouble b
pFromSql (H.SqlRational b) = PersistDouble $ fromRational b
pFromSql (H.SqlLocalDate d) = PersistDay d
pFromSql (H.SqlLocalTimeOfDay d) = PersistTimeOfDay d
pFromSql (H.SqlUTCTime d) = PersistUTCTime d
pFromSql H.SqlNull = PersistNull
pFromSql x = PersistString $ H.fromSql x -- FIXME