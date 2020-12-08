-- |
-- Copyright   : (c) 2019 Charlie Jacomme <charlie.jacomme@lsv.fr>
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Robert Künnemann <robert@kunnemann.de>
-- Portability : GHC only
--
-- We try to compress as much as possible the MSR rules
--
--

-- Two rules can be merged if they do not merge obaservable actions.
--

module Sapic.Compression (
    pathCompression
) where
import Control.Monad.Catch
import qualified Data.Set              as S

import qualified Data.List              as List
import qualified Extension.Data.Label                as L
import Theory
import Theory.Sapic
import Sapic.Facts
import Theory.Model.Fact

import         Text.PrettyPrint.Class

import Debug.Trace

-- We compress as much as possible silent actions
--

isOutFact :: Fact t -> Bool
isOutFact (Fact OutFact _ _) = True
isOutFact _                 = False

isStateFact :: Fact LNTerm -> Bool
isStateFact (Fact (ProtoFact _ name _) _ _) =
  "State" `List.isPrefixOf` name
  ||
  "Semistate" `List.isPrefixOf` name
isStateFact _ = False

isFreshFact :: Fact LNTerm -> Bool
isFreshFact (Fact FreshFact _ _ ) = True
isFreshFact _ = False

-- get all rules with premice the given fact
getPremRules:: Fact LNTerm ->  [Rule ProtoRuleEInfo] -> ([Rule ProtoRuleEInfo],[Rule ProtoRuleEInfo])
getPremRules fact rules =
  List.partition  (\x -> List.any (==fact) (L.get rPrems x)) rules

-- get all rules producing the given fact
getConcsRules:: Fact LNTerm ->  [Rule ProtoRuleEInfo] -> ([Rule ProtoRuleEInfo],[Rule ProtoRuleEInfo])
getConcsRules fact rules =
  List.partition  (\x -> List.any (==fact) (L.get rConcs x)) rules

-- Get the list of all state facts produced by a rule
getProducedFacts :: [Rule ProtoRuleEInfo] -> S.Set (Fact LNTerm)
getProducedFacts rules =
  facts
  where
    facts = List.foldl (\acc (Rule _ _ rconc _ _) ->
                              List.foldl (\set y -> y `S.insert` set) acc (List.filter isStateFact rconc)
                           ) S.empty rules

-- TODO : how to merge the info about a rule
mergeInfo :: ProtoRuleEInfo -> ProtoRuleEInfo -> ProtoRuleEInfo
mergeInfo info info2 =
  ProtoRuleEInfo (StandRule (name++";"++name2)) (attr++attr2) (res ++ res2)
 where ProtoRuleEInfo (StandRule name) attr res= info
       ProtoRuleEInfo (StandRule name2) attr2 res2= info2

canMerge  :: Rule ProtoRuleEInfo -> Rule ProtoRuleEInfo -> Bool
canMerge r1 r2
  | ((ract /= []) && (ract2 /= [])) = False  -- we cannot merge rules if it makes events be simulataneous
  | (List.length rprem2 > 1) && (List.length rconc >1) = False   -- we cannot merge rules if we are breaking asynchronous behavior (i.e u->v,w and w,r->t cannot be compress, as r might be produced byi
  | (List.length rconc > 1) && (ract2 /= []) = False   -- we cannot merge rules if we are breaking asynchronous behavior (i.e u->v,w, and v-E->t cannot be compressed, else an event that could have happened with w before E cannot do so anymore.
  | (List.any isOutFact rconc) && (List.any isOutFact rconc2) = False -- we cannot merge rules if two Out become simultaneous (might break the fact that the attacker can know smth and not smth else at a timepoint
  | (List.any isOutFact rconc) && (ract2 /= []) = False -- we cannot merge rules if a Out and an event become simultaneous (might break the fact that the attacker can know smth and not smth else at a timepoint
  |otherwise = True
  where Rule _ _ rconc ract _ = r1
        Rule _ rprem2 rconc2 ract2 _ = r2

-- We try to merge two rules together, and add the result or themselves in case of failure to a set
merge:: Rule ProtoRuleEInfo -> Rule ProtoRuleEInfo -> S.Set (Rule ProtoRuleEInfo) ->S.Set (Rule ProtoRuleEInfo)
merge rule1 rule2 ruleset =
  if canMerge rule1 rule2 then
    (Rule (mergeInfo rinfo rinfo2) newprem newrconc (ract++ract2) (rnew++rnew2)) `S.insert` ruleset
  else
    rule1 `S.insert` (rule2 `S.insert` ruleset)
  where Rule rinfo rprem rconc ract rnew = rule1
        Rule rinfo2 rprem2 rconc2 ract2 rnew2 = rule2
        newprem = rprem ++ (List.filter (\x -> not(List.elem x rconc)) rprem2)
        newrconc = rconc2 ++ (List.filter (\x -> not(List.elem x rprem2)) rconc)

-- Given two set of rules, such that the leftrules all produce a state (the same) consumed by the right rules, try to compress rules for each possible pairing between rules in leftrules and rightrules
mergeRules::  [Rule ProtoRuleEInfo] -> [Rule ProtoRuleEInfo] -> [Rule ProtoRuleEInfo]
mergeRules leftrules rightrules =
  S.toList rulesset
  where rulesset = List.foldl (\set l -> List.foldl (\set2 r-> merge l r set2) set rightrules) S.empty leftrules


showR (Rule (ProtoRuleEInfo name _ _) rprem rconc ract rnew) = show (Rule (ProtoRuleEInfo name [] [] ) rprem rconc ract rnew) <> "\n"

showRs rs = concat $ map showR rs
  -- Given a fact and an msr, compress the msr with respect to this fact, and return the new msr, and the new facts (facts reachable in one step from the fact) that we may try to compress
compressOne :: Fact LNTerm -> [Rule ProtoRuleEInfo] -> ([Rule ProtoRuleEInfo], S.Set (Fact LNTerm))
compressOne fact msr
  | isPersistentFact fact =  trace (show new_facts)  (msr, new_facts)
  | otherwise =  trace (show new_facts) (msr3 ++ new_rules, new_facts)
  where (prem_rules,msr2) = getPremRules fact msr
        (concs_rules,msr3) = getConcsRules fact msr2
        new_rules = mergeRules concs_rules prem_rules
        new_facts = trace (showRs new_rules) getProducedFacts new_rules

-- Compress one by one the facts inside the given list, maintaining a set of already compressed facts to avoid loops, and adding the new facts to explore progressively.
compress :: [Fact LNTerm] -> S.Set (Fact LNTerm) -> [Rule ProtoRuleEInfo] -> [Rule ProtoRuleEInfo]
compress [] _ msr = msr
compress (fact:remainder) compressed_facts msr =
  trace "test" $ compress new_facts_remainder new_compressed_facts new_msr
  where (new_msr,new_facts) = compressOne fact msr
        new_compressed_facts = fact `S.insert` compressed_facts
        new_facts_no_compress = new_facts S.\\ new_compressed_facts
        new_facts_no_remainder = new_facts_no_compress S.\\ (S.fromList remainder)
        new_facts_remainder = ((S.toList new_facts_no_remainder)++remainder)   -- we avoid duplicates between remainder and newfactsnocompress


-- Start the compression by the init fact introduced by the translation
pathCompression:: MonadCatch m =>
    [Rule ProtoRuleEInfo] -> m [Rule ProtoRuleEInfo]
pathCompression msr =
  return (compress [initfact] S.empty msr)
  where initfact = Sapic.Facts.factToFact (State LState [] S.empty)
