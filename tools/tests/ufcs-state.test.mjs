import test from 'node:test';
import assert from 'node:assert/strict';
import {ufcsState} from '../../webroot/ufcs.js';
const base={schema:'1',state:'ok',active:'0',value:'1',effective_disabled:'0',configured_disable:'0',boot_apply:'0',config_valid:'1',can_set:'1'};
test('UFCS UI uses actual override and distinguishes driver thermal votes',()=>{
  assert.equal(ufcsState(base).overridden,false);
  const blocked=ufcsState({...base,effective_disabled:'1'});
  assert.equal(blocked.blocked,true);assert.equal(blocked.overridden,false);assert.equal(blocked.canSet,true);
  const applied=ufcsState({...base,active:'1',effective_disabled:'1',boot_apply:'1',configured_disable:'1'});
  assert.equal(applied.overridden,true);assert.equal(applied.bootApply,true);
});
test('UFCS UI fails closed on unknown, inconsistent and malformed snapshots',()=>{
  for(const bad of [{},{...base,schema:'2'},{...base,state:'unavailable'},{...base,active:'2'},
    {...base,value:'-1'},{...base,active:'1',effective_disabled:'0'},
    {...base,active:'1',value:'0',effective_disabled:'1'},{...base,boot_apply:'1'}]) {
    assert.equal(ufcsState(bad).canSet,false);
  }
});
test('saved boot preference does not pretend current inhibit remains active',()=>{
  const state=ufcsState({...base,configured_disable:'1',boot_apply:'1'});
  assert.equal(state.bootApply,true);assert.equal(state.overridden,false);
  assert.equal(state.canSet,true);
});
