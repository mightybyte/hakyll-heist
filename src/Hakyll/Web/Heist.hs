{-# LANGUAGE OverloadedStrings #-}

{-

This file is part of the package hakyll-heist. It is subject to the
license terms in the LICENSE file found in the top-level directory of
this distribution and at git://pmade.com/hakyll-heist/LICENSE.  No
part of hakyll-heist package, including this file, may be copied,
modified, propagated, or distributed except according to the terms
contained in the LICENSE file.

-}

--------------------------------------------------------------------------------
module Hakyll.Web.Heist
  ( loadDefaultHeist
  , loadHeist
  , applyTemplate
  , applyTemplateList
  , applyJoinTemplateList
  , Content
  , SpliceT
  , State
  ) where

--------------------------------------------------------------------------------
import           Blaze.ByteString.Builder (toByteString)
import           Control.Error (runEitherT)
import           Control.Monad (liftM)
import           Control.Monad.Reader (ReaderT(..), ask)
import           Control.Monad.Trans (lift)
import           Data.ByteString (ByteString)
import           Data.ByteString.UTF8 (toString, fromString)
import           Data.List (intersperse)
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import           Text.XmlHtml
import qualified Data.Text as T

--------------------------------------------------------------------------------
import           Hakyll.Core.Compiler
import           Hakyll.Core.Item
import           Hakyll.Web.Template.Context

--------------------------------------------------------------------------------
import           Heist
import qualified Heist.Interpreted as I

--------------------------------------------------------------------------------
type Content a = (Context a, Item a)
type SpliceT a = ReaderT (Content a) Compiler
type State   a = HeistState (SpliceT a)

--------------------------------------------------------------------------------
-- | Load all of the templates from the given directory and return an
-- initialized 'HeistState' using the given splices (in addition to
-- the default splices and the @hakyll@ splice).
loadHeist :: FilePath
          -- ^ Directory containing the templates.
          -> [(T.Text, I.Splice (SpliceT a))]
          -- ^ List of compiled Heist slices.
          -> [(T.Text, AttrSplice (SpliceT a))]
          -- ^ List of Heist attribute slices.
          -> IO (State a)
loadHeist baseDir a b = do
    tState <- runEitherT $ do
        let splices' = [("hakyll", hakyllSplice)] ++ a
            attrs = [("url", urlAttrSplice)] ++ b
            hc = HeistConfig splices' defaultLoadTimeSplices [] attrs
                 [loadTemplates baseDir]
        initHeist hc
    either (error . concat) return tState

--------------------------------------------------------------------------------
-- | Load all of the templates from the given directory and return an
-- initialized 'HeistState' with the default splices.
loadDefaultHeist :: FilePath -> IO (State a)
loadDefaultHeist baseDir = loadHeist baseDir [] []

--------------------------------------------------------------------------------
-- | Apply a Heist template to a Hakyll 'Item'.  You need a
-- 'HeistState' from either the 'loadDefaultHeist' function or the
-- 'loadHeist' function.
applyTemplate :: State a                 -- ^ HeistState
              -> ByteString              -- ^ Template name
              -> Context a               -- ^ Context
              -> Item a                  -- ^ Page
              -> Compiler (Item String)  -- ^ Resulting item
applyTemplate state name context item = do
    result <- runReaderT (I.renderTemplate state name) (context, item)
    case result of
      Nothing    -> fail badTplError
      Just (b,_) -> return $ itemSetBody (toString $ toByteString b) item
    where badTplError = "failed to render template: " ++ toString name

--------------------------------------------------------------------------------
-- | Render the given list of 'Item's with the given Heist template
-- and return everything concatenated together.
applyTemplateList :: State a    -- ^ HeistState.
                  -> ByteString -- ^ Template name.
                  -> Context a  -- ^ Context.
                  -> [Item a]   -- ^ List of items.
                  -> Compiler String
applyTemplateList = applyJoinTemplateList ""

--------------------------------------------------------------------------------
-- | Render the given list of 'Item's with the given Heist template.
-- The content of the items is joined together using the given string
-- delimiter.
applyJoinTemplateList :: String     -- ^ Delimiter.
                      -> State a    -- ^ HeistState.
                      -> ByteString -- ^ Template name.
                      -> Context a  -- ^ Context.
                      -> [Item a]   -- ^ List of items.
                      -> Compiler String
applyJoinTemplateList delimiter state name context items = do
    items' <- mapM (applyTemplate state name context) items
    return $ concat $ intersperse delimiter $ map itemBody items'

--------------------------------------------------------------------------------
-- Internal function to render the @hakyll@ splice given fields inside
-- of a 'Context'.
hakyllSplice :: I.Splice (SpliceT a)
hakyllSplice = do
    node <- getParamNode
    (context, item) <- lift ask
    let context' f = unContext (context <> missingField) f item
    case lookup "field" $ elementAttrs node of
      Nothing -> fail fieldError
      Just f  -> do content <- lift $ lift $ context' $ T.unpack f
                    lift $ lift $ renderField (elementAttrs node) content
    where fieldError = "The `hakyll' splice is missing the `field' attribute"

--------------------------------------------------------------------------------
renderField :: [(T.Text, T.Text)] -> String -> Compiler Template
renderField attrs content =
  case as of
    "html" -> parse html
    "xml"  -> parse xml
    "text" -> return [TextNode $ T.pack content]
    _      -> fail "the `as' attribute should be text, html, or xml"
  where as    = fromMaybe "text" $ lookup "as" attrs
        name  = "Hakyll field splice"
        parse = either fail (return . docContent)
        html  = parseHTML name (fromString content)
        xml   = parseXML  name (fromString content)

--------------------------------------------------------------------------------
-- Attribute splice: changes a bare @url@ attribute to a complete
-- @href@ attribute using the URL from the current 'Context'.  While
-- the default replacement attribute is @href@ this can be overridden
-- by supplying a value for the @url@ attribute:
--
-- > <img url="src"/>
--
-- This function exists mostly to serve as an example for writing your
-- own attribute splices.
urlAttrSplice :: AttrSplice (SpliceT a)
urlAttrSplice a = do
  (context, item) <- lift ask
  let url = unContext (context <> missingField) "url" item
  val <- lift $ lift $ liftM T.pack url
  return $ (if T.null a then "href" else a, val) : []
