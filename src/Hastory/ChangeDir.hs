{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}

module Hastory.ChangeDir where

import Import

import Hastory.OptParse.Types
import Hastory.Recent

change :: (MonadIO m, MonadReader Settings m) => Int -> m ()
change ix = do
    recentDirOpts <- getRecentDirOpts
    liftIO $
        case recentDirOpts `atMay` ix of
            Nothing -> die "Invalid index choice."
            Just d -> putStrLn d
