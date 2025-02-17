{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module OpenTelemetry.Instrumentation.Yesod
  (
  -- * Middleware functionality
  openTelemetryYesodMiddleware,
  RouteRenderer(..),
  mkRouteToRenderer,
  mkRouteToPattern,
  -- * Utilities
  rheSiteL,
  handlerEnvL
  ) where

import Data.Maybe (catMaybes)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Lens.Micro
import qualified OpenTelemetry.Context as Context
import OpenTelemetry.Context.ThreadLocal
import OpenTelemetry.Trace.Core hiding (inSpan, inSpan', inSpan'')
import OpenTelemetry.Trace.Monad
import Yesod.Core
import Yesod.Core.Types
import Language.Haskell.TH.Syntax
import Network.Wai (requestHeaders)
import Yesod.Routes.TH.Types
import UnliftIO.Exception
import Data.Text (Text)
import Data.List (intercalate)

handlerEnvL :: Lens' (HandlerData child site) (RunHandlerEnv child site)
handlerEnvL = lens handlerEnv (\h e -> h { handlerEnv = e })
{-# INLINE handlerEnvL #-}

rheSiteL :: Lens' (RunHandlerEnv child site) site
rheSiteL = lens rheSite (\rhe new -> rhe { rheSite = new })
{-# INLINE rheSiteL #-}

instance MonadTracer (HandlerFor site) where
  getTracer = do
    tp <- getGlobalTracerProvider
    OpenTelemetry.Trace.Core.getTracer tp "hs-opentelemetry-instrumentation-yesod" tracerOptions

-- | Template Haskell to generate a function named routeToRendererFunction.
--
-- For a route like HomeR, this function returns "HomeR".
--
-- For routes with parents, this function returns e.g. "FooR.BarR.BazR".
mkRouteToRenderer :: Name -> [ResourceTree a] -> Q [Dec]
mkRouteToRenderer appName ress = do
  let fnName = mkName "routeToRenderer"
      t1 `arrow` t2 = ArrowT `AppT` t1 `AppT` t2

  clauses <- mapM (goTree id []) ress

  pure
    [ SigD fnName ((ConT ''Route `AppT` ConT appName) `arrow` ConT ''Text)
    , FunD fnName $ concat clauses
    ]

goTree :: (Pat -> Pat) -> [String] -> ResourceTree a -> Q [Clause]
goTree front names (ResourceLeaf res) = pure <$> goRes front names res
goTree front names (ResourceParent name _check pieces trees) =
  concat <$> mapM (goTree front' newNames) trees
  where
    ignored = (replicate toIgnore WildP ++) . pure
    toIgnore = length $ filter isDynamic pieces
    isDynamic Dynamic {} = True
    isDynamic Static {} = False
#if MIN_VERSION_template_haskell(2, 18, 0)
    front' = front . ConP (mkName name) [] . ignored
#else
    front' = front . ConP (mkName name) . ignored
#endif
    newNames = names <> [name]

goRes :: (Pat -> Pat) -> [String] -> Resource a -> Q Clause
goRes front names Resource {..} =
  pure $
    Clause
      [front $ RecP (mkName resourceName) []]
      (NormalB $ toText $ intercalate "." (names <> [resourceName]))
      []
  where
    toText s = VarE 'T.pack `AppE` LitE (StringL s)

mkRouteToPattern :: Name -> [ResourceTree String] -> Q [Dec]
mkRouteToPattern appName ress = do
  let fnName = mkName "routeToPattern"
      t1 `arrow` t2 = ArrowT `AppT` t1 `AppT` t2

  clauses <- mapM mkClause $ flatten ress

  pure
    [ SigD fnName ((ConT ''Route `AppT` ConT appName) `arrow` ConT ''Text)
    , FunD fnName clauses
    ]

  where
    toText s = VarE 'T.pack `AppE` LitE (StringL s)
    isDynamic Dynamic {} = True
    isDynamic Static {} = False
#if MIN_VERSION_template_haskell(2, 18, 0)
    parentPieceWrapper (parentName, pieces) nestedPat = ConP (mkName parentName) [] $ mconcat
#else
    parentPieceWrapper (parentName, pieces) nestedPat = ConP (mkName parentName) $ mconcat
#endif
      [ replicate (length $ filter isDynamic pieces) WildP
      , [nestedPat]
      ]
    mkClause fr@FlatResource{..} = do
      let clausePattern = foldr parentPieceWrapper (RecP (mkName frName) []) frParentPieces
      pure $ Clause
        [clausePattern]
        (NormalB $ toText $ renderPattern fr)
        []

renderPattern :: FlatResource String -> String
renderPattern FlatResource{..} = concat $ concat
  [ if frCheck then [] else ["!"]
  , case formattedParentPieces <> concatMap routePortionSection frPieces of
      [] -> ["/"]
      pieces -> pieces
  , case frDispatch of
      Methods{..} -> concat
        [ case methodsMulti of
            Nothing -> []
            Just t -> ["/+", t]
        ]
      Subsite{} -> []
  ]
  where
    routePortionSection :: Piece String -> [String]
    routePortionSection (Static t) = ["/", t]
    routePortionSection (Dynamic t) = ["/#{", t, "}"]

    formattedParentPieces :: [String]
    formattedParentPieces = do
      (_parentName, pieces) <- frParentPieces
      piece <- pieces
      routePortionSection piece

data RouteRenderer site = RouteRenderer
  { nameRender :: Route site -> T.Text
  , pathRender :: Route site -> T.Text
  }

openTelemetryYesodMiddleware
  :: (ToTypedContent res)
  => RouteRenderer site
  -> HandlerFor site res
  -> HandlerFor site res
openTelemetryYesodMiddleware rr m = do
  -- tracer <- OpenTelemetry.Trace.Monad.getTracer
  req <- waiRequest
  mspan <- Context.lookupSpan <$> getContext
  mr <- getCurrentRoute
  let sharedAttributes = catMaybes
        [ do
            r <- mr
            pure ("http.route", toAttribute $ pathRender rr r)
        , do
            ff <- lookup "X-Forwarded-For" $ requestHeaders req
            pure ("http.client_ip", toAttribute $ T.decodeUtf8 ff)
        ]
      args = defaultSpanArguments
        { kind = maybe Server (const Internal) mspan
        , attributes = sharedAttributes
        }
  mapM_ (`addAttributes` sharedAttributes) mspan
  eResult <- inSpan' (maybe "yesod.handler.notFound" (\r -> "yesod.handler." <> nameRender rr r) mr) args $ \_s -> do
    catch (Right <$> m) $ \e -> do
      -- We want to mark the span as an error if it's an InternalError,
      -- the other HCError values are 4xx status codes which don't
      -- really count as a server error in OpenTelemetry spec parlance.
      case e of
        HCError (InternalError _) -> throwIO e
        _ -> pure ()
      pure (Left (e :: HandlerContents))
  case eResult of
    Left hc -> throwIO hc
    Right normal -> pure normal
