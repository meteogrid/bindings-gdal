{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

#include "bindings.h"

module OGRSpec (main, spec, setupAndTeardown) where

import Control.Applicative ((<$>), (<*>))
import Control.Monad (void, when, forM_)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Catch (try, throwM)

import Data.ByteString (ByteString)
import Data.Conduit (($$), (=$=))
import qualified Data.Conduit.List as CL
import Data.Either (isRight)
import Data.Int
import Data.Word
import Data.Maybe (isNothing, isJust)
import Data.Monoid (mempty)
import Data.Text (Text)
import Data.Time
import Data.Typeable (Typeable, typeOf)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

import System.Mem (performMajorGC)
import System.FilePath (joinPath)

import GDAL (
    GDAL
  , ErrorNum(..)
  , GDALException(..)
  )
import OGR
import OSR

import Paths_bindings_gdal

import TestUtils

main :: IO ()
main = hspec spec

spec :: Spec
spec = setupAndTeardown $ do

  describe "DataSource and layer" $ do

    it "cannot open a non-existent file" $ do
      openReadOnly "foo.shp" `shouldThrow` ((==OpenFailed) . gdalErrNum)

    it "can open a shape file" $ do
      void $ getShapePath >>= openReadOnly

    it "can get datasource name" $ do
      n <- getShapePath >>= openReadOnly >>= datasourceName
      n `shouldContain` "fondo.shp"

    it "can get a layer by index" $ do
      void $ getShapePath >>= openReadOnly >>= getLayer 0

    it "cannot get a layer by wrong index" $ do
      (getShapePath >>= openReadOnly >>= getLayer (-1))
        `shouldThrow` (==InvalidLayerIndex (-1))

    it "can get a layer by name" $ do
      void $ getShapePath >>= openReadOnly >>= getLayerByName "fondo"

    it "cannot get a layer by wrong name" $ do
      (getShapePath >>= openReadOnly >>= getLayerByName "foo")
        `shouldThrow` (==InvalidLayerName "foo")

    it "can get layer count" $ do
      n <- getShapePath >>= openReadOnly >>= layerCount
      n `shouldBe` 1

    it "can get layer name" $ do
      n <- getShapePath >>= openReadOnly >>= getLayer 0 >>= layerName
      n `shouldBe` "fondo"

    withDir "can create ShapeFile" $ \d -> do
      let p = joinPath [d, "test.shp"]
      void $ create "ESRI Shapefile" p []

    it "create throws on invalid driver name" $
      create "foo" "" [] `shouldThrow` (==(UnknownDriver "foo"))

    describe "createLayerWithDef" $ do
      let check fd = do
            ds <- createMem []
            l <- createLayerWithDef ds fd StrictOK []
            layerFeatureDef l >>= (`shouldBe` fd)

      it "works with unicode name and field names" $
        check (FeatureDef { fdName   = "Barça Players"
                          , fdFields = [ strField "contraseña", realField "año"]
                          , fdGeom   = pointDef
                          , fdGeoms  = mempty})

      it "works with a single geometry field with no srs" $
        check (FeatureDef { fdName   = "Barça Players"
                          , fdFields = mempty
                          , fdGeom   = pointDef
                          , fdGeoms  = mempty})

      it "works with a single geometry field with srs" $ do
        check (FeatureDef { fdName   = "Barça Players"
                          , fdFields = mempty
                          , fdGeom   = pointDef {gfdSrs = Just srs23030}
                          , fdGeoms  = mempty})

      when canCreateMultipleGeometryFields $ do
        it "works with several geometry field with no srs" $ do
          check (FeatureDef { fdName   = "Barça Players"
                            , fdFields = mempty
                            , fdGeom   = pointDef
                            , fdGeoms  = [("another_geom", pointDef)]})

        it "works with several geometry field with srs" $ do
          check (FeatureDef { fdName   = "Barça Players"
                            , fdFields = mempty
                            , fdGeom   = pointDef
                            , fdGeoms  = [( "another_geom"
                                          , pointDef {gfdSrs = Just srs23030})]})

    describe "layer CRUD" $ do
      forM_ (["Memory", "ESRI Shapefile"] :: [String]) $ \driverName -> do
        describe ("with " ++ driverName ++ " driver") $ do

          withDir "can create and retrieve a feature" $ \tmpDir -> do
            let feat = TestFeature aPoint ("some data" :: String)
            ds <- create driverName (joinPath [tmpDir, "test"]) []
            l <- createLayer ds StrictOK []
            fid <- createFeature l feat
            getFeature l fid >>= (`shouldBe` Just feat)

          withDir "can create and delete a feature" $ \tmpDir -> do
            let feat = TestFeature aPoint ("some data" :: String)
            ds <- create driverName (joinPath [tmpDir, "test"]) []
            l <- createLayer ds StrictOK []
            fid <- createFeature l feat
            getFeature l fid >>= (`shouldSatisfy` isJust)
            deleteFeature l fid
            getFeature l fid >>= (`shouldSatisfy` isNothing)

          withDir "can create and update a feature" $ \tmpDir -> do
            let feat  = TestFeature aPoint ("some data" :: String)
                feat2 = feat {tfData="other data"}
            ds <- create driverName (joinPath [tmpDir, "test"]) []
            l <- createLayer ds StrictOK []
            fid <- createFeature l feat
            getFeature l fid >>= (`shouldBe` Just feat)
            updateFeature l fid feat2
            getFeature l fid >>= (`shouldBe` Just feat2)

          withDir "can sink and then source features" $ \tmpDir -> do
            let fs = map (TestFeature aPoint) [1..1000 :: Int32]
            ds <- create driverName (joinPath [tmpDir, "test"]) []
            CL.sourceList fs $$ sinkInsertLayer_ (createLayer ds StrictOK [])
            fs' <- sourceLayer_ (getLayer 0 ds) $$ CL.consume
            fs `shouldBe` fs'


      withDir "can retrieve features with less fields than present in layer" $
        \tmpDir -> do
          let path = joinPath [tmpDir, "test.shp"]
              name = "Test"
              someData = "dfsdgfsdgsdf" :: Text
              feat = feature aPoint [ "name"   .= ("Pepe" :: Text)
                                    , "height" .= (187 :: Double)
                                    , "data"   .= someData
                                    ]
              expected = Just (TestFeature aPoint someData)
              fDef =
                FeatureDef {
                  fdName   = name
                , fdFields = [ "name"   `fieldTypedAs` (undefined :: Text)
                             , "height" `fieldTypedAs` (undefined :: Double)
                             , "data"   `fieldTypedAs` (undefined :: String)
                             ]
                , fdGeom   = GeomFieldDef WkbPoint Nothing True
                , fdGeoms  = mempty}
          ds <- create "ESRI Shapefile" path []
          l <- createLayerWithDef ds fDef StrictOK []
          fid <- createFeature l feat
          syncToDisk l
          l2 <- openReadOnly path >>= getLayerByName name
          getFeature l2 fid >>= (`shouldBe` expected)



  describe "getSpatialFilter" $ do

    it "return Noting when no filter has been set" $ do
      mGeom <- getShapePath >>= openReadOnly >>= getLayer 0 >>= getSpatialFilter
      mGeom `shouldSatisfy` isNothing

    it "can set a spatial filter and retrieve it" $ do
      l <- getShapePath >>= openReadWrite >>= getLayer 0
      setSpatialFilter l aPoint
      mGeom <- getSpatialFilter l
      mGeom `shouldBe` Just aPoint


  describe "executeSQL" $ do

    it "can execute a valid query with DefaultDialect" $ do
      ds <- getShapePath >>= openReadOnly
      let src = executeSQL_ DefaultDialect "SELECT * FROM fondo" Nothing ds
      (fs :: [Feature]) <- src $$ CL.consume
      length fs `shouldBe` 2

    it "throws error on invalid query" $ do
      ds <- getShapePath >>= openReadOnly
      let src = executeSQL_ DefaultDialect "dis is NoSQL!" Nothing ds
          isSqlError e = case e of {SQLQueryError _ -> True; _ -> False}
      (src $$ CL.consume >>= \(_::[Feature])->undefined)
        `shouldThrow` isSqlError


  describe "Geometry" $ do

    describe "createFromWkt / exportToWkt" $ do

      it "succeeds if valid" $ do
        let eGeom = createFromWkt Nothing "POINT (34 21)"
        eGeom `shouldSatisfy` isRight

      it "fails if invalid" $ do
        let eGeom = createFromWkt Nothing "im not wkt"
        eGeom `shouldBe` Left UnsupportedGeometryType

      it "export is same as original" $ do
        let Right g = createFromWkt Nothing wkt
            wkt     = "POINT (34 21)"
        exportToWkt g `shouldBe` wkt

    describe "createFromWkb / exportToWkb" $ do

      it "succeeds if valid" $ do
        let Right g = createFromWkt Nothing "POINT (34 21)"
            wkb     = exportToWkb WkbXDR g
        createFromWkb Nothing wkb `shouldSatisfy` isRight

      it "fails if invalid" $ do
        let eGeom = createFromWkb Nothing "im not wkb"
        eGeom `shouldBe` Left CorruptData


    it "compares equal when equal with no srs" $ do
      createFromWkt Nothing "POINT (2 5)"
        `shouldBe` createFromWkt Nothing "POINT (2 5)"

    it "compares equal when equal with srs" $ do
      let Right srs = fromWkt (toWkt srs23030)
      srs `shouldBe` srs23030
      createFromWkt (Just srs) "POINT (2 5)"
        `shouldBe` createFromWkt (Just srs23030) "POINT (2 5)"

    it "compares not equal when not equal" $ do
      createFromWkt Nothing "POINT (2 6)"
        `shouldNotBe` createFromWkt Nothing "POINT (2 5)"

    describe "geometrySpatialReference" $ do

      it "is Nothing when it has no srs" $ do
        let Right g = createFromWkt Nothing "POINT (34 21)"
        geometrySpatialReference g `shouldSatisfy` isNothing

      it "is is the same as the one that was set" $ do
        let Right g = createFromWkt (Just srs23030) "POINT (34 21)"
        geometrySpatialReference g `shouldBe` Just srs23030

    describe "transformWith" $ do

      it "transforms a geometry without srs" $ do
        let Right g         = createFromWkt Nothing "POINT (439466 4482586)"
            Right expected  = createFromWkt (Just srs4326)
                                "POINT (-3.715491503365956 40.489899869998304)"
            Just coordTrans = coordinateTransformation srs23030 srs4326
        case g `transformWith` coordTrans of
          Nothing -> expectationFailure "Should have transformed the geom"
          Just t  -> do
            geometrySpatialReference t `shouldBe` Just srs4326
            -- We compare WKT or else they won't match (TODO investigate why!)
            --t  `shouldBe` expected
            exportToWkt t  `shouldBe` exportToWkt expected

    describe "transformTo" $ do

      it "transforms a geometry" $ do
        let Right g         = createFromWkt (Just srs23030)
                                "POINT (439466 4482586)"
            Right expected  = createFromWkt (Just srs4326)
                                "POINT (-3.715491503365956 40.489899869998304)"
        case g `transformTo` srs4326 of
          Nothing -> expectationFailure "Should have transformed the geom"
          Just t  -> do
            geometrySpatialReference t `shouldBe` Just srs4326
            -- We compare WKT or else they won't match (TODO investigate why!)
            --t  `shouldBe` expected
            exportToWkt t  `shouldBe` exportToWkt expected


  describe "OGRField instances" $
    forM_ (["Memory", "ESRI Shapefile"] :: [String]) $ \driverName -> do
      describe ("'"++driverName++"' driver") $ do
#if SUPPORTS_WORD_FIELDS
        ogrFieldSpec driverName (34 :: Int)
        ogrFieldSpec driverName (0 :: Int)
        ogrFieldSpec driverName (minBound :: Int)
        ogrFieldSpec driverName (maxBound :: Int)
        ogrFieldSpec driverName (34 :: Word)
        ogrFieldSpec driverName (0 :: Int)
        ogrFieldSpec driverName (minBound :: Word)
        ogrFieldSpec driverName (maxBound :: Word)

        ogrFieldSpec driverName (mempty :: [Int])
        ogrFieldSpec driverName ([0,34,76,minBound,maxBound] :: [Int])
        ogrFieldSpec driverName (mempty :: U.Vector Int)
        ogrFieldSpec driverName ([0,34,76,minBound,maxBound] :: U.Vector Int)
#else
        ogrFieldSpec driverName (34 :: Int32)
        ogrFieldSpec driverName (0 :: Int32)
        ogrFieldSpec driverName (minBound :: Int32)
        ogrFieldSpec driverName (maxBound :: Int32)
        ogrFieldSpec driverName (34 :: Word32)
        ogrFieldSpec driverName (0 :: Int32)
        ogrFieldSpec driverName (minBound :: Word32)
        ogrFieldSpec driverName (maxBound :: Word32)

        ogrFieldSpec driverName (mempty :: [Int32])
        ogrFieldSpec driverName ([0,34,76,minBound,maxBound] :: [Int32])
        ogrFieldSpec driverName (mempty :: U.Vector Int32)
        ogrFieldSpec driverName ([0,34,76,minBound,maxBound] :: U.Vector Int32)
#endif
        ogrFieldSpec driverName (3.4 :: Double)
        ogrFieldSpec driverName (3.4 :: Float)

        -- FIXME
        -- ogrFieldSpec driverName (mempty :: Text)
        -- ogrFieldSpec driverName (mempty :: String)

        ogrFieldSpec driverName ("foo" :: Text)
        ogrFieldSpec driverName ("foo" :: String)

        ogrFieldSpec driverName (mempty :: ByteString)
        ogrFieldSpec driverName ("\x0\x0\x0\0\xDE\xCA\xFF" :: ByteString)

        ogrFieldSpec driverName (mempty :: [Float])
        ogrFieldSpec driverName ([0,34,76,0] :: [Float])
        ogrFieldSpec driverName (mempty :: U.Vector Float)
        ogrFieldSpec driverName ([0,34,76,0] :: U.Vector Float)
        ogrFieldSpec driverName (mempty :: [Double])
        ogrFieldSpec driverName ([0,34,76,0] :: [Double])
        ogrFieldSpec driverName (mempty :: U.Vector Double)
        ogrFieldSpec driverName ([0,34,76,0] :: U.Vector Double)

        ogrFieldSpec driverName (mempty :: [Text])
        ogrFieldSpec driverName (["foo","bar"] :: [Text])
        ogrFieldSpec driverName (mempty :: V.Vector Text)
        ogrFieldSpec driverName (["foo","bar"] :: V.Vector Text)
        ogrFieldSpec driverName (mempty :: [String])
        ogrFieldSpec driverName (["foo", "bar"] :: [String])
        ogrFieldSpec driverName (mempty :: V.Vector String)
        ogrFieldSpec driverName (["foo", "bar"] :: V.Vector String)

        ogrFieldSpec driverName (UTCTime (fromGregorian 2010 01 04) 0)
        ogrFieldSpec driverName (UTCTime (fromGregorian 2010 01 04) 5437)
        ogrFieldSpec driverName
          (LocalTime (fromGregorian 2010 01 04) (TimeOfDay 20 21 34))
        ogrFieldSpec driverName
          (ZonedTime
            (LocalTime (fromGregorian 2010 01 04) (TimeOfDay 21 45 32))
            utc)
        ogrFieldSpec driverName
          (ZonedTime
            (LocalTime (fromGregorian 2010 01 04) (TimeOfDay 22 11 59))
            (minutesToTimeZone 60))
        ogrFieldSpec driverName
          (ZonedTime
            (LocalTime (fromGregorian 2010 01 04) (TimeOfDay 23 59 58))
            (minutesToTimeZone (-60)))
        ogrFieldSpec driverName (fromGregorian 2010 01 04)
        ogrFieldSpec driverName (TimeOfDay 20 00 00)

instance Eq ZonedTime where
  a == b = zonedTimeToUTC a == zonedTimeToUTC b

getShapePath :: GDAL s FilePath
getShapePath = liftIO $ getDataFileName "tests/fixtures/fondo.shp"

setupAndTeardown :: SpecWith a -> SpecWith a
setupAndTeardown = after_ performMajorGC

strField, realField :: Text -> (Text, FieldDef)
strField  name = (name, FieldDef OFTString  Nothing Nothing Nothing True)
realField name = (name, FieldDef OFTReal    Nothing Nothing Nothing True)

pointDef :: GeomFieldDef
pointDef = GeomFieldDef WkbPoint Nothing True

aPoint :: Geometry
aPoint = either exc id (createFromWkt Nothing "POINT (45 87)")
  where exc  = error . ("Unexpected createFromWkt error: " ++) . show

srs23030 :: SpatialReference
srs23030 = either exc id (fromEPSG 23030)
  where exc = error . ("Unexpected fromEPSG error: " ++) . show

srs4326 :: SpatialReference
srs4326 = either exc id (fromEPSG 4326)
  where exc = error . ("Unexpected fromEPSG error: " ++) . show

data TestFeature a
  = TestFeature  {
      tfGeom :: Geometry
    , tfData :: a
  } deriving (Eq, Show)

instance OGRField a => OGRFeature (TestFeature a) where
  toFeature TestFeature{..} = feature tfGeom ["data" .= tfData]
  fromFeature f             = TestFeature <$> theGeom f <*> f .: "data"


instance OGRField a => OGRFeatureDef (TestFeature a) where
  featureDef _ =
    FeatureDef {
      fdName   = "Test"
    , fdFields = ["data" `fieldTypedAs` (undefined :: a)]
    , fdGeom   = GeomFieldDef WkbPoint Nothing True
    , fdGeoms  = mempty}

ogrFieldSpec
  :: forall a. (
    OGRFeatureDef (TestFeature (Maybe a))
  , OGRFeatureDef (TestFeature a)
  , Typeable a
  , OGRField a
  , Typeable (Maybe a)
  , Eq (Maybe a)
  , Eq a
  , Show (Maybe a)
  , Show a
  )
  => String -> a -> SpecWith (Arg (IO ()))
ogrFieldSpec driverName v = do
  let typeName = show (typeOf (undefined :: a))
      suiteName =
        "feature with '"++typeName++"' field comes out of layer as it got in"
  describe suiteName $ do
    ogrFieldSpec_ v
    ogrFieldSpec_ (Just v)
    ogrFieldSpec_ (Nothing :: Maybe a)

  where
    ogrFieldSpec_ value = do
      let feat = TestFeature aPoint value
          tyName  = show (typeOf value)

      withDir (show value) $ \tmpDir -> do
        ds <- create driverName (joinPath [tmpDir, "test"]) []
        r <- try $ do
          l <- createLayer ds StrictOK []
          createFeature l feat >>= getFeature l >>= (`shouldBe` Just feat)
        case r of
          Right () -> return ()
          Left GDALException{gdalErrNum=NotSupported} ->
            -- driver does not support it, oh well...
            warn ("Not supported by '"++driverName++"' driver: " ++ tyName)
          Left e  -> throwM e