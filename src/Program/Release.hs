{-# LANGUAGE MultiWayIf #-}

module Program.Release (program, determineReleaseState) where

import           Control.Applicative               ((<$>))
import           Control.Monad                     ((<=<))
import           Control.Monad.Trans.Class         (lift)
import           Control.Monad.Trans.Either        (hoistEither, runEitherT)
import           Control.Monad.Trans.Writer.Strict (WriterT, runWriterT, tell)
import           Data.Maybe                        (fromMaybe, fromJust, listToMaybe, isNothing)
import           Data.List                         (isPrefixOf)

import           Types                             (Branch (..),
                                                    Environment (..),
                                                    ReleaseState (..), Tag (..),
                                                    Version (..),
                                                    tmpBranch)

import           Interpreter.Commands              (EWP, Program, deployTag,
                                                    outputMessage,
                                                    getLineAfterPrompt,
                                                    gitCheckoutNewBranchFromTag,
                                                    gitCreateAndCheckoutBranch,
                                                    gitCheckoutBranch,
                                                    gitCheckoutTag, gitPushTags,
                                                    gitRemoveTag, gitRemoveBranch, gitTag,
                                                    gitTags, gitBranches, gitMergeNoFF
                                                    )

import           Tags                              (ciTagFilter,
                                                    defaultReleaseCandidateTag,
                                                    defaultReleaseTag,
                                                    getAllCandidatesForRelease,
                                                    getNextReleaseCandidateTag,
                                                    getReleaseTagFromCandidate,
                                                    isReleaseCandidateTag,
                                                    latestFilteredTag,
                                                    releaseCandidateTagFilter,
                                                    releaseTagFilter)


{- TODO: need to handle the case where one of these tags does not exist -}
determineReleaseState :: [Tag] -> [Branch] -> ReleaseState
determineReleaseState tags branches =
  let
    latestReleaseCandidate = fromMaybe
      defaultReleaseCandidateTag $
      latestFilteredTag releaseCandidateTagFilter tags
    bugfixBranch = findReleaseCandidateBugfixBranch latestReleaseCandidate branches
    latestRelease = fromMaybe
      defaultReleaseTag $
      latestFilteredTag releaseTagFilter tags
  in
  case bugfixBranch of
    Just branch -> ReleaseInProgressBugfix latestReleaseCandidate branch
    Nothing ->
      if latestReleaseCandidate > latestRelease
      then ReleaseInProgress latestReleaseCandidate
      else NoReleaseInProgress latestRelease

-- TODO handle case when there are multipe matching branches
findReleaseCandidateBugfixBranch :: Tag -> [Branch] -> Maybe Branch
findReleaseCandidateBugfixBranch releaseCandidateTag = 
  listToMaybe . filter (isPrefixOf ((show releaseCandidateTag) ++ "/bugs") . show)

program :: Program [String]
program = do
  -- strip WriterT by returning its accumulated logs
  snd <$> runWriterT tellErrors

  where
    tellErrors :: WriterT [String] Program ()
    tellErrors = do
      -- strip EitherT by just shoving the error message (in case of error) into the underlying writer transformer
      eitherResult <- runEitherT release
      either
        (tell . (:[]))
        return
        eitherResult

    release :: EWP ()
    release = do
      tags <- gitTags
      branches <- gitBranches
      case determineReleaseState tags branches of
        ReleaseInProgress latestReleaseCandidate -> do
          outputMessage $ "Release candidate found: " ++ (show latestReleaseCandidate)
          yesOrNo <- promptForYesOrNo "Is this release candidate good? y(es)/n(o):"
          case yesOrNo of
            True -> releaseCandidate latestReleaseCandidate
            False -> do
              bugBranchName <- getLineAfterPrompt "What bug are you fixing? (specify dash separated descriptor, e.g. 'theres-a-bug-in-the-code'): "
              let bugFixBranch = Branch ((show latestReleaseCandidate) ++ "/bugs/" ++ bugBranchName)
              gitCheckoutTag latestReleaseCandidate
              gitCreateAndCheckoutBranch $ tmpBranch latestReleaseCandidate
              gitCreateAndCheckoutBranch bugFixBranch
              outputMessage $ "Created branch: " ++ (show bugFixBranch) ++ ", fix your bug!"

        NoReleaseInProgress latestReleaseTag -> do
          -- checkout latest green build
          lastGreenTag <- hoistEither $ maybeToEither "Could not find latest green tag" $ latestFilteredTag ciTagFilter tags
          outputMessage $ "No outstanding release candidate found, starting new release candidate from: " ++ (show lastGreenTag)
          gitCheckoutTag lastGreenTag
          let releaseCandidateTag = getNextReleaseCandidateTag latestReleaseTag
          gitTag releaseCandidateTag
          outputMessage $ "Started new release: " ++ show releaseCandidateTag ++ ", deploy to preproduction and confirm the release is good to go!"
          gitPushTags "origin"

        ReleaseInProgressBugfix latestReleaseCandidate branch -> do
          outputMessage $ "Bugfix found: " ++ show branch
          yesOrNo <- promptForYesOrNo "Is the bug fixed? y(es)/n(o):"
          case yesOrNo of
            True -> do
              gitCheckoutBranch $ tmpBranch latestReleaseCandidate
              gitMergeNoFF branch
              gitRemoveBranch branch
              let nextReleaseCandidateTag = getNextReleaseCandidateTag latestReleaseCandidate
              gitTag $ nextReleaseCandidateTag
              outputMessage $ "Created new release candidate: " ++ show nextReleaseCandidateTag ++ ", you'll get it this time!"
              gitPushTags "origin"
              gitRemoveBranch $ tmpBranch latestReleaseCandidate
            False -> do
              gitCheckoutBranch branch
              outputMessage "Keep fixing that code!"

      where
        releaseCandidate latestReleaseCandidate = do
          gitCheckoutTag latestReleaseCandidate
          let releaseTag = getReleaseTagFromCandidate latestReleaseCandidate
          gitTag releaseTag
          gitPushTags "origin"
          outputMessage $ "Created tag: " ++ (show releaseTag) ++ ", deploy to production cowboy!"

        maybeToEither = flip maybe Right . Left

        promptForYesOrNo :: String -> EWP Bool
        promptForYesOrNo prompt = do
          parseYesOrNo <$> (getLineAfterPrompt prompt) >>= (\answer -> if isNothing answer then promptForYesOrNo prompt else return $ fromJust answer)

        parseYesOrNo :: String -> Maybe Bool
        parseYesOrNo "y"   = Just True
        parseYesOrNo "yes" = Just True
        parseYesOrNo "n"   = Just False
        parseYesOrNo "no"  = Just False
        parseYesOrNo  _    = Nothing

