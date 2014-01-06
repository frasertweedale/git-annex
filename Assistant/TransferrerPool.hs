{- A pool of "git-annex transferkeys" processes
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.TransferrerPool where

import Assistant.Common
import Assistant.Types.TransferrerPool
import Logs.Transfer
import Utility.Batch

import qualified Command.TransferKeys as T

import Control.Concurrent.STM hiding (check)
import System.Process (create_group, std_in, std_out)
import Control.Exception (throw)
import Control.Concurrent

{- Runs an action with a Transferrer from the pool.
 -
 - Only one Transferrer is left running in the pool at a time.
 - So if this needed to start a new Transferrer, it's stopped when done.
 -}
withTransferrer :: FilePath -> BatchCommandMaker -> TransferrerPool -> (Transferrer -> IO a) -> IO a
withTransferrer program batchmaker pool a = do
	i@(TransferrerPoolItem (Just t) _) <- maybe
		(mkTransferrerPoolItem pool =<< mkTransferrer program batchmaker)
		(checkTransferrerPoolItem program batchmaker)
			=<< atomically (popTransferrerPool pool)
	v <- tryNonAsync $ a t
	sz <- atomically $ pushTransferrerPool pool i
	when (sz > 1) $
		void $ forkIO $ stopTransferrer t
	either throw return v

{- Check if a Transferrer from the pool is still ok to be used.
 - If not, stop it and start a new one. -}
checkTransferrerPoolItem :: FilePath -> BatchCommandMaker -> TransferrerPoolItem -> IO TransferrerPoolItem
checkTransferrerPoolItem program batchmaker i = case i of
	TransferrerPoolItem (Just t) check -> ifM check
		( return i
		, do
			stopTransferrer t
			new check
		)
	TransferrerPoolItem Nothing check -> new check
  where
	new check = do
		t <- mkTransferrer program batchmaker
		return $ TransferrerPoolItem (Just t) check

{- Requests that a Transferrer perform a Transfer, and waits for it to
 - finish. -}
performTransfer :: Transferrer -> Transfer -> AssociatedFile -> IO Bool
performTransfer transferrer t f = catchBoolIO $ do
	T.sendRequest t f (transferrerWrite transferrer)
	T.readResponse (transferrerRead transferrer)

{- Starts a new git-annex transferkeys process, setting up handles
 - that will be used to communicate with it. -}
mkTransferrer :: FilePath -> BatchCommandMaker -> IO Transferrer
mkTransferrer program batchmaker = do
	{- It runs as a batch job. -}
	let (program', params') = batchmaker (program, [Param "transferkeys"])
	{- It's put into its own group so that the whole group can be
	 - killed to stop a transfer. -}
	(Just writeh, Just readh, _, pid) <- createProcess
		(proc program' $ toCommand params')
		{ create_group = True
		, std_in = CreatePipe
		, std_out = CreatePipe
		}
	fileEncoding readh
	fileEncoding writeh
	return $ Transferrer
		{ transferrerRead = readh
		, transferrerWrite = writeh
		, transferrerHandle = pid
		}

{- Checks if a Transferrer is still running. If not, makes a new one. -}
checkTransferrer :: FilePath -> BatchCommandMaker -> Transferrer -> IO Transferrer
checkTransferrer program batchmaker t =
	maybe (return t) (const $ mkTransferrer program batchmaker)
		=<< getProcessExitCode (transferrerHandle t)

{- Closing the fds will stop the transferrer. -}
stopTransferrer :: Transferrer -> IO ()
stopTransferrer t = do
	hClose $ transferrerRead t
	hClose $ transferrerWrite t
	void $ waitForProcess $ transferrerHandle t
