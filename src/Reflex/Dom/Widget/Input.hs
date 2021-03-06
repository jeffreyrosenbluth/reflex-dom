{-# LANGUAGE ConstraintKinds, TypeFamilies, FlexibleContexts, DataKinds, GADTs, ScopedTypeVariables, FlexibleInstances, RecursiveDo, TemplateHaskell #-}
module Reflex.Dom.Widget.Input where

import Prelude

import Reflex.Dom.Class
import Reflex.Dom.Widget.Basic

import Reflex
import Reflex.Host.Class
import GHCJS.DOM.HTMLInputElement
import GHCJS.DOM.HTMLTextAreaElement
import GHCJS.DOM.Element
import GHCJS.DOM.HTMLSelectElement
import GHCJS.DOM.EventM
import GHCJS.DOM.UIEvent
import Data.Monoid
import Data.Map as Map
import Control.Lens
import Control.Monad hiding (forM_)
import Control.Monad.IO.Class
import Data.Default
import Data.Maybe
import Safe
import Data.Dependent.Sum (DSum (..))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Foldable

input' :: MonadWidget t m => String -> String -> Event t String -> Dynamic t (Map String String) -> m (TextInput t)
input' inputType initial eSetValue dAttrs = do
  e <- liftM castToHTMLInputElement $ buildEmptyElement "input" =<< mapDyn (Map.insert "type" inputType) dAttrs
  liftIO $ htmlInputElementSetValue e initial
  performEvent_ $ fmap (liftIO . htmlInputElementSetValue e) eSetValue
  eChange <- wrapDomEvent e elementOninput $ liftIO $ htmlInputElementGetValue e
  postGui <- askPostGui
  runWithActions <- askRunWithActions
  eChangeFocus <- newEventWithTrigger $ \eChangeFocusTrigger -> do
    unsubscribeOnblur <- liftIO $ elementOnblur e $ liftIO $ do
      postGui $ runWithActions [eChangeFocusTrigger :=> False]
    unsubscribeOnfocus <- liftIO $ elementOnfocus e $ liftIO $ do
      postGui $ runWithActions [eChangeFocusTrigger :=> True]
    return $ liftIO $ unsubscribeOnblur >> unsubscribeOnfocus
  dFocus <- holdDyn False eChangeFocus
  eKeypress <- wrapDomEvent e elementOnkeypress $ liftIO . uiEventGetKeyCode =<< event
  eKeydown <- wrapDomEvent e elementOnkeydown $ liftIO . uiEventGetKeyCode =<< event
  eKeyup <- wrapDomEvent e elementOnkeyup $ liftIO . uiEventGetKeyCode =<< event
  dValue <- holdDyn initial $ leftmost [eSetValue, eChange]
  return $ TextInput dValue eKeypress eKeydown eKeyup dFocus e

{-  
  dSetValue <- holdDyn "" eSetValue
  dynText =<< combineDyn (\v a -> "Input placeholder: " <> show (inputType, v, a)) dSetValue dAttrs
  return $ TextInput (constDyn "") never never never (constDyn False) (constDyn Nothing)

input' inputType eSetValue dAttrs = do
  dEffectiveAttrs <- mapDyn (Map.insert "type" inputType) dAttrs
  let mkSelf (initialValue, initialAttrs) = do
        doc <- askDocument
        Just e <- liftIO $ liftM (fmap castToHTMLInputElement) $ documentCreateElement doc "input"
        liftIO $ htmlInputElementSetValue e initialValue
        iforM_ initialAttrs $ \attr value -> liftIO $ elementSetAttribute e attr value
        eChange <- wrapDomEvent e elementOninput $ liftIO $ htmlInputElementGetValue e
        runFrame <- askRunFrame
        eChangeFocus <- newEventWithTrigger $ \eChangeFocusTrigger -> do
          unsubscribeOnblur <- liftIO $ elementOnblur e $ liftIO $ do
            runFrame $ DMap.singleton eChangeFocusTrigger False
          unsubscribeOnfocus <- liftIO $ elementOnfocus e $ liftIO $ do
            runFrame $ DMap.singleton eChangeFocusTrigger True
          return $ liftIO $ unsubscribeOnblur >> unsubscribeOnfocus
        eKeypress <- wrapDomEvent e elementOnkeypress $ liftIO . uiEventGetKeyCode =<< event
        eKeydown <- wrapDomEvent e elementOnkeydown $ liftIO . uiEventGetKeyCode =<< event
        eKeyup <- wrapDomEvent e elementOnkeyup $ liftIO . uiEventGetKeyCode =<< event
        return (e, eChange, eKeypress, eKeydown, eKeyup, eChangeFocus)
  dInitialValue <- holdDyn "" eSetValue
  dInitial <- combineDyn (,) dInitialValue dEffectiveAttrs
  eCreated <- performEvent . fmap mkSelf . tagDyn dInitial =<< getEInit
  dMyElement <- holdDyn Nothing $ fmap (Just . (^. _1)) eCreated
  performEvent_ . updated =<< combineDyn (maybe (const $ return ()) $ \e attrs -> liftIO $ setElementAttributes e attrs) dMyElement dEffectiveAttrs
  putEChildren $ fmap ((:[]) . toNode . (^. _1)) eCreated
  performEvent_ $ fmapMaybe (fmap $ \(e,v) -> liftIO $ htmlInputElementSetValue e v) $ attachWith (\e v -> case e of
    Nothing -> Nothing
    Just e' -> Just (e',v)) (current dMyElement) eSetValue
  eChange <- liftM switch $ hold never $ fmap (^. _2) eCreated
  dFocus <- holdDyn False . switch =<< hold never (fmap (^. _6) eCreated) --TODO: Check that 'False' is always the correct starting value - i.e.: an element will always receive an 'onfocus' event, even if it gets focus immediately
  dValue <- holdDyn "" $ leftmost [eSetValue, eChange]
  eKeypress <- liftM switch $ hold never $ fmap (^. _3) eCreated
  eKeydown <- liftM switch $ hold never $ fmap (^. _4) eCreated
  eKeyup <- liftM switch $ hold never $ fmap (^. _5) eCreated
  return $ TextInput dValue eKeypress eKeydown eKeyup dFocus dMyElement
-}

class HasValue a where
  type Value a :: *
  value :: a -> Value a

data TextInput t
  = TextInput { _textInput_value :: Dynamic t String
              , _textInput_keypress :: Event t Int
              , _textInput_keydown :: Event t Int
              , _textInput_keyup :: Event t Int
              , _textInput_hasFocus :: Dynamic t Bool
              , _textInput_element :: HTMLInputElement
              }

instance HasValue (TextInput t) where
  type Value (TextInput t) = Dynamic t String
  value = _textInput_value

textInput :: MonadWidget t m => m (TextInput t)
textInput = input' "text" "" never (constDyn $ Map.empty)

textInputGetEnter :: Reflex t => TextInput t -> Event t ()
textInputGetEnter i = fmapMaybe (\n -> if n == keycodeEnter then Just () else Nothing) $ _textInput_keypress i

data TextAreaConfig t
  = TextAreaConfig { _textAreaConfig_initialValue :: String
                   , _textAreaConfig_setValue :: Event t String
                   , _textAreaConfig_attributes :: Dynamic t (Map String String)
                   }

instance Reflex t => Default (TextAreaConfig t) where
  def = TextAreaConfig { _textAreaConfig_initialValue = ""
                       , _textAreaConfig_setValue = never
                       , _textAreaConfig_attributes = constDyn mempty
                       }

data TextArea t
  = TextArea { _textArea_value :: Dynamic t String
             , _textArea_element :: HTMLTextAreaElement
             , _textArea_hasFocus :: Dynamic t Bool
             , _textArea_keypress :: Event t Int
             }

instance HasValue (TextArea t) where
  type Value (TextArea t) = Dynamic t String
  value = _textArea_value

textArea :: MonadWidget t m => TextAreaConfig t -> m (TextArea t)
textArea (TextAreaConfig initial eSet attrs) = do
  e <- liftM castToHTMLTextAreaElement $ buildEmptyElement "textarea" attrs
  liftIO $ htmlTextAreaElementSetValue e initial
  postGui <- askPostGui
  runWithActions <- askRunWithActions
  eChangeFocus <- newEventWithTrigger $ \eChangeFocusTrigger -> do
    unsubscribeOnblur <- liftIO $ elementOnblur e $ liftIO $ do
      postGui $ runWithActions [eChangeFocusTrigger :=> False]
    unsubscribeOnfocus <- liftIO $ elementOnfocus e $ liftIO $ do
      postGui $ runWithActions [eChangeFocusTrigger :=> True]
    return $ liftIO $ unsubscribeOnblur >> unsubscribeOnfocus
  performEvent_ $ fmap (liftIO . htmlTextAreaElementSetValue e) eSet
  f <- holdDyn False eChangeFocus
  ev <- wrapDomEvent e elementOninput $ liftIO $ htmlTextAreaElementGetValue e
  v <- holdDyn "" $ leftmost [eSet, ev]
  eKeypress <- wrapDomEvent e elementOnkeypress $ liftIO . uiEventGetKeyCode =<< event
  return $ TextArea v e f eKeypress

{-
type family Controller sm t a where
  Controller Edit t a = (a, Event t a) -- Initial value and setter
  Controller View t a = Dynamic t a -- Value (always)

type family Output sm t a where
  Output Edit t a = Dynamic t a -- Value (always)
  Output View t a = Event t a -- Requested changes

data CheckboxConfig sm t
   = CheckboxConfig { _checkbox_input :: Controller sm t Bool
                    , _checkbox_attributes :: Attributes
                    }

instance Reflex t => Default (CheckboxConfig Edit t) where
  def = CheckboxConfig (False, never) mempty

data Checkbox sm t
  = Checkbox { _checkbox_output :: Output sm t Bool
             }

data StateMode = Edit | View

--TODO: There must be a more generic way to get this witness and allow us to case on the type-level StateMode
data StateModeWitness (sm :: StateMode) where
  EditWitness :: StateModeWitness Edit
  ViewWitness :: StateModeWitness View

class HasStateModeWitness (sm :: StateMode) where
  stateModeWitness :: StateModeWitness sm

instance HasStateModeWitness Edit where
  stateModeWitness = EditWitness

instance HasStateModeWitness View where
  stateModeWitness = ViewWitness
-}

data CheckboxConfig t
   = CheckboxConfig { _checkboxConfig_setValue :: Event t Bool
                    , _checkboxConfig_attributes :: Map String String
                    }

instance Reflex t => Default (CheckboxConfig t) where
  def = CheckboxConfig { _checkboxConfig_setValue = never
                       , _checkboxConfig_attributes = Map.empty
                       }

data Checkbox t
  = Checkbox { _checkbox_value :: Dynamic t Bool
             }

--TODO: Make attributes possibly dynamic
-- | Create an editable checkbox
--   Note: if the "type" or "checked" attributes are provided as attributes, they will be ignored
checkbox :: MonadWidget t m => Bool -> CheckboxConfig t -> m (Checkbox t)
checkbox checked config = do
  e <- liftM castToHTMLInputElement $ buildEmptyElement "input" $ Map.insert "type" "checkbox" $ (if checked then Map.insert "checked" "checked" else Map.delete "checked") (_checkboxConfig_attributes config)
  eClick <- wrapDomEvent e elementOnclick $ liftIO $ htmlInputElementGetChecked e
  performEvent_ $ fmap (\v -> liftIO $ htmlInputElementSetChecked e $! v) $ _checkboxConfig_setValue config
  dValue <- holdDyn checked $ leftmost [_checkboxConfig_setValue config, eClick]
  return $ Checkbox dValue

checkboxView :: MonadWidget t m => Dynamic t (Map String String) -> Dynamic t Bool -> m (Event t Bool)
checkboxView dAttrs dValue = do
  e <- liftM castToHTMLInputElement $ buildEmptyElement "input" =<< mapDyn (Map.insert "type" "checkbox") dAttrs
  eClicked <- wrapDomEvent e elementOnclick $ do
    preventDefault
    liftIO $ htmlInputElementGetChecked e
  schedulePostBuild $ do
    v <- sample $ current dValue
    when v $ liftIO $ htmlInputElementSetChecked e True
  performEvent_ $ fmap (\v -> liftIO $ htmlInputElementSetChecked e $! v) $ updated dValue
  return eClicked

checkboxWithLabel :: forall t m. MonadWidget t m => String -> m (Checkbox t)
checkboxWithLabel l = checkboxWithLabelAttrs l Map.empty

checkboxWithLabelAttrs :: forall t m. MonadWidget t m => String -> Map String String -> m (Checkbox t)
checkboxWithLabelAttrs l attrs = elAttr "label" attrs $ do
  c <- checkbox False def
  text $ " " <> l
  return c


data Dropdown t k
   = Dropdown { _dropdown_value :: Dynamic t k
              }

--TODO: We should allow the user to specify an ordering instead of relying on the ordering of the Map
--TODO: Get rid of Show k and Read k by indexing the possible values ourselves
-- | Create a dropdown box
--   The first argument gives the initial value of the dropdown; if it is not present in the map of options provided, it will be added with an empty string as its text
dropdownDynAttr :: forall k t m. (MonadWidget t m, Ord k, Show k, Read k) => Dynamic t (Map String String) -> k -> Event t k -> Dynamic t (Map k String) -> m (Dropdown t k)
dropdownDynAttr attrs k0 setK options = do
  (eRaw, _) <- elDynAttr' "select" attrs $ do
    optionsWithDefault <- mapDyn (`Map.union` (k0 =: "")) options
    listWithKey optionsWithDefault $ \k v -> do
      elAttr "option" ("value" =: show k <> if k == k0 then "selected" =: "selected" else mempty) $ dynText v
  let e = castToHTMLSelectElement $ _el_element eRaw
  performEvent_ $ fmap (liftIO . htmlSelectElementSetValue e . show) setK
  eChange <- wrapDomEvent e elementOnchange $ do
    kStr <- liftIO $ htmlSelectElementGetValue e
    return $ readMay kStr
  let readKey opts mk = fromMaybe k0 $ do
        k <- mk
        guard $ Map.member k opts
        return k
  dValue <- combineDyn readKey options =<< holdDyn (Just k0) (leftmost [eChange, fmap Just setK])
  return $ Dropdown dValue

dropdown :: forall k t m. (MonadWidget t m, Ord k, Show k, Read k) => k -> Dynamic t (Map k String) -> m (Dropdown t k)
dropdown k = dropdownDynAttr (constDyn Map.empty) k never

--TODO: Get rid of Show k and Read k by indexing the possible values ourselves
dropdown' :: forall k t m. (MonadWidget t m, Eq k, Show k, Read k) => k -> NonEmpty (k, String) -> m (Dropdown t k)
dropdown' k0 ks = do
  (eRaw, _) <- elAttr' "select" ("class" =: "form-control") $ do
    forM_ ks $ \(k, name) -> do
      elAttr "option" ("value" =: show k <> if k == k0 then "selected" =: "selected" else mempty) $ text name
  let e = castToHTMLSelectElement $ _el_element eRaw
  eChange <- wrapDomEvent e elementOnchange $ do
    kStr <- liftIO $ htmlSelectElementGetValue e
    return $ readMay kStr
  let readKey mk = fromMaybe k0 mk
  dValue <- mapDyn readKey =<< holdDyn (Just k0) eChange
  return $ Dropdown dValue

listDropdown :: (MonadWidget t m) => Dynamic t [a] -> (a -> String) -> Dynamic t (Map String String) -> String -> m (Dynamic t (Maybe a))
listDropdown xs f attrs defS = do
  m <- mapDyn (Map.fromList . zip [(1::Int)..]) xs
  sel <- liftM _dropdown_value $ dropdownDynAttr attrs 0 never =<< mapDyn ((Map.insert 0 defS) . Map.map f) m
  combineDyn Map.lookup sel m

--TODO Remove CSS Classes
searchInputResult :: forall t m a. MonadWidget t m => Dynamic t (String, a) -> m (Event t (String, a))
searchInputResult r = el "li" $ do
  (li, _) <- elAttr' "a" (Map.singleton "style" "cursor: pointer;") $ dynText =<< mapDyn fst r
  return $ tag (current r) (_el_clicked li)

searchInput :: forall t m a k. (MonadWidget t m, Ord k) => Map k (String, a) -> Event t (Map k (String, a)) -> m (Event t String, Event t (String, a))
searchInput initial results = searchInput' initial results searchInputResultsList

searchInput' :: forall t m a k. (MonadWidget t m, Ord k) => Map k (String, a) -> Event t (Map k (String, a)) -> (Dynamic t (Map k (String, a)) -> m (Event t (String, a))) -> m (Event t String, Event t (String, a))
searchInput' initial results listBuilder = do
  rec input <- input' "text" "" eSetValue $ constDyn $ Map.fromList [("class", "form-control"), ("placeholder", "Search")]
      dResults <- holdDyn initial $ leftmost [eClearResults, results]
      eMadeChoice <- listBuilder dResults
      let eSetValue = fmap fst eMadeChoice
          eSelectionMade = fmap (const Nothing) eSetValue
          eInputChanged = fmapMaybe id $ leftmost [eSelectionMade, fmap Just (updated $ _textInput_value input)]
          eInputEmpty = fmapMaybe id $ fmap (\i -> if i == "" then Just Map.empty else Nothing) eInputChanged
          eClearResults = leftmost [eInputEmpty, fmap (const Map.empty) eMadeChoice]
  return (eInputChanged, eMadeChoice)

searchInputResultsList :: forall t m a k. (MonadWidget t m, Ord k) => Dynamic t (Map k (String, a)) -> m (Event t (String, a))
searchInputResultsList results = searchInputResultsList' results (flip list searchInputResult)

searchInputResultsList' :: forall t m a k. (MonadWidget t m, Ord k) => Dynamic t (Map k (String, a)) -> (Dynamic t (Map k (String, a)) -> m (Dynamic t (Map k (Event t (String, a))))) -> m (Event t (String, a))
searchInputResultsList' results builder = do
  let hideDropdown = Map.fromList [("class", "dropdown-menu"), ("style", "display: none;")]
      showDropdown = Map.fromList [("class", "dropdown-menu"), ("style", "display: block;")]
  attrs <- mapDyn (\rs -> if Map.null rs then hideDropdown else showDropdown) results
  resultsList <- elDynAttr "ul" attrs $ builder results
  liftM switch $ hold never $ fmap (leftmost . Map.elems) (updated resultsList)

liftM concat $ mapM makeLenses
  [ ''TextAreaConfig
  , ''TextArea
  , ''TextInput
  ]

class HasAttributes a where
  type Attrs a :: *
  attributes :: Lens' a (Attrs a)

instance HasAttributes (TextAreaConfig t) where
  type Attrs (TextAreaConfig t) = Dynamic t (Map String String)
  attributes = textAreaConfig_attributes

class HasSetValue a where
  type SetValue a :: *
  setValue :: Lens' a (SetValue a)

instance HasSetValue (TextAreaConfig t) where
  type SetValue (TextAreaConfig t) = Event t String
  setValue = textAreaConfig_setValue
