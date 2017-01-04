{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}


module Main where

import           Args
import           Control.Lens
import           Control.Monad.IO.Class
import           Control.Monad.Trans.AWS
import           Data.Conduit
import qualified Data.Conduit.Binary as CB
import           Data.Monoid
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Network.AWS.Auth
import           Network.AWS.S3
import           Network.AWS.S3.Encryption
import           Network.AWS.S3.Encryption.Types
import           Network.AWS.STS
import           Network.URI
import           System.Directory
import           System.FilePath
import           System.IO


main:: IO ()
main = runWithArgs $ \ args@Args{..} -> do

  env <- getAwsEnv args

  let keyEnv = KeyEnv env (kmsKey argsKmsKey)

  (s3Bucket, s3Obj) <- case parseS3URI argsS3Uri
                         of Left e -> error e
                            Right bo -> return bo

  -- if a file is not given we interact with stdin/out
  hBinMode stdin
  hBinMode stdout

  let s3kmsDecrypt = runResourceT . runAWST keyEnv $ do
        res <- decrypt (getObject s3Bucket s3Obj)
        let cOut = case argsFileName
                     of Nothing -> CB.sinkHandle stdout
                        Just f -> do liftIO $ mkParentDirs f
                                     CB.sinkFile f
        view gorsBody res `sinkBody` cOut

      s3kmsEncrypt = runResourceT . runAWST keyEnv $ do
        oBody <- case argsFileName
                   of Nothing -> fmap toBody $ CB.sourceHandle stdin $$ CB.sinkLbs
                      Just f -> fmap toBody $ hashedFile f

        -- an unnecessary extra bit of paranoia, encrypt at rest with default S3 key
        let req = (set poServerSideEncryption (Just AES256))
                    (putObject s3Bucket s3Obj oBody)

        _ <- encrypt req
        return ()

  case argsCmd
    of CmdGet -> s3kmsDecrypt
       CmdPut -> s3kmsEncrypt


getAwsEnv :: Args
          -> IO Env
getAwsEnv Args{..} = do
  lgr <- newLogger (if argsVerbose then Debug else Info) stderr

  let setReg = case argsRegion
                 of Nothing -> id
                    Just r -> set envRegion r

      setLgr = set envLogger lgr

  initialEnv <- (setLgr . setReg) <$>
                ( case argsAwsProfile
                    of Nothing -> newEnv Discover
                       Just p  -> do cf <- credFile
                                     newEnv $ FromFile p cf )

  let sessionCreds stsCreds = FromSession ((AccessKey . TE.encodeUtf8)    (stsCreds ^. cAccessKeyId))
                                          ((SecretKey . TE.encodeUtf8)    (stsCreds ^. cSecretAccessKey))
                                          ((SessionToken . TE.encodeUtf8) (stsCreds ^. cSessionToken))

  case argsAwsRoleArn
    of Nothing -> return initialEnv
       Just r -> runResourceT . runAWST initialEnv $ do
                   res <- send $ assumeRole r "kmsrole"
                   case view arrsCredentials res
                     of Just cr -> setLgr <$> newEnv (sessionCreds cr)
                        Nothing -> error $ "Unable to assume AWS role " <> (show argsAwsRoleArn)


parseS3URI :: String
           -> Either String (BucketName, ObjectKey)
parseS3URI s3u = do
  URI{..} <- case parseURI s3u
               of Nothing -> Left $ "Failed to parse URI " <> s3u
                  Just u -> Right u

  _ <- if uriScheme == "s3:"
       then Right ()
       else Left $ "Expected s3: URI scheme in " <> s3u <> " but got " <> uriScheme

  URIAuth{..} <- case uriAuthority
                   of Nothing -> Left $ "Expected authority part in an s3 uri, got " <> s3u
                      Just a -> Right a

  objKey <- if null uriPath
            then Left $ "URI path must not be empty (object key part) in " <> s3u
            else (Right . T.tail . T.pack) uriPath -- skip 1st '/'

  return ( ((BucketName . T.pack) uriRegName)
         , (ObjectKey objKey) )


mkParentDirs :: FilePath
             -> IO ()
mkParentDirs fp = do
  let (dir, _) = splitFileName fp
  createDirectoryIfMissing True dir


hBinMode :: Handle
         -> IO ()
hBinMode h = do
  hSetBinaryMode h True
  hSetBuffering  h (BlockBuffering Nothing)
