{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Data.Hastory.Server where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Logger (MonadLogger)
import Control.Monad.Logger.CallStack (logInfo)
import Data.Hastory.API
import Data.Hastory.Types (Entry(..))
import Data.Proxy (Proxy(..))
import Data.Semigroup ((<>))
import qualified Data.Text as T
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Options.Applicative as A
import Prelude
import Servant
import System.Posix.Files (fileExist)
import System.Random (newStdGen, randomRs)

data Options =
  Options
    { _oPort :: Int
    -- ^ Port that will be used by the server.
    , _oDataOutputFilePath :: FilePath
      -- ^ Path of the file to which received commands will be appended.
    , _oLogFile :: Maybe String
      -- ^ If provided, server will log to this file. If not provided, server
      -- doesn't log anything by default.
    }
  deriving (Show, Eq)

newtype ServerSettings =
  ServerSettings
    { _ssToken :: T.Text
    -- ^ Token that is used to authenticate Hastory Remote Storage users. This token will
      -- be generated by the server on startup and clients are required to pass this token in the header named X-Token.
      --
      -- Currently, upon restarts, server generates a brand-new token, resulting in invalidating every request thereon.
      -- This issue may be solved by saving the token in disk and having another command line flag for generating a new
      -- token.
    }
  deriving (Show, Eq)

-- | Parser for the command line flags of Hastory Server.
optParser :: A.ParserInfo Options
optParser =
  A.info
    (Options <$> A.option A.auto (A.value 8080 <> A.showDefault <> A.long "port" <> A.short 'p') <*>
     A.strOption (A.value ".hastory_data" <> A.long "data-directory" <> A.short 'd') <*>
     A.option A.auto (A.value (Just "server.logs") <> A.long "log-output" <> A.short 'l'))
    mempty

-- | Main server logic for Hastory Server.
server :: Options -> ServerSettings -> Server HastoryAPI
server Options {..} ServerSettings {..} = sAppendCommand
  where
    sAppendCommand :: Maybe Token -> Entry -> Handler ()
    sAppendCommand (Just (Token token)) command
      | token == _ssToken = liftIO $ appendFile _oDataOutputFilePath (show command <> "\n")
      | otherwise = throwError $ err403 {errBody = "Invalid Token provided."}
    sAppendCommand Nothing _ =
      throwError $ err403 {errBody = tokenHeaderKey <> " header should exist."}

-- | Proxy for Hastory API.
myApi :: Proxy HastoryAPI
myApi = Proxy

-- | Main warp application. Consumes requests and produces responses.
app :: Options -> ServerSettings -> Application
app options serverSettings = serve myApi (server options serverSettings)

-- | Logging action that will be executed with every request.
mkWarpLogger :: FilePath -> Wai.Request -> HTTP.Status -> Maybe Integer -> IO ()
mkWarpLogger logPath req _ _ = appendFile logPath $ show req <> "\n"

-- | Warp server settings.
mkWarpSettings :: Options -> Warp.Settings
mkWarpSettings Options {..} =
  Warp.setTimeout 20 $
  Warp.setPort _oPort $ maybe id (Warp.setLogger . mkWarpLogger) _oLogFile Warp.defaultSettings

-- | How long the generated token should be.
tokenLength :: Int
tokenLength = 20

-- | Generate a random token that this server requires with every request.
-- See @_ssToken@ for more info.
generateToken :: MonadIO m => m T.Text
generateToken = T.pack . take tokenLength . randomRs ('a', 'z') <$> liftIO newStdGen
  -- | Displays the port this server will use. This port is configurable via command-line flags.

reportPort :: MonadLogger m => Options -> m ()
reportPort Options {..} = logInfo $ "Starting server on port " <> T.pack (show _oPort)
  -- | Logs information about the data file. This data file serves as a database for this primitive append-only server.

reportDataFileStatus :: (MonadIO m, MonadLogger m) => Options -> m ()
reportDataFileStatus Options {..} = do
  dataFileExists <- liftIO $ fileExist _oDataOutputFilePath
  if dataFileExists
    then logInfo $
         "Data file exists at " <> T.pack _oDataOutputFilePath <> ". Appending commands to it."
    else logInfo "Data file doesn't exist. Creating a new one."
  -- | Starts a webserver by reading command line flags.

hastoryServer :: (MonadIO m, MonadLogger m) => m ()
hastoryServer = do
  options@Options {..} <- liftIO $ A.execParser optParser
  reportPort options
  reportDataFileStatus options
  token <- generateToken
  logInfo $ "Token: " <> token
  liftIO $ Warp.runSettings (mkWarpSettings options) (app options (ServerSettings token))
