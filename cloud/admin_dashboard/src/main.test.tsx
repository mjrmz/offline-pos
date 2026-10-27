import React from 'react';
import {afterEach,expect,test,vi} from 'vitest';
import {cleanup,fireEvent,render,screen,waitFor,within} from '@testing-library/react';
import {App} from './main';

const customer={id:'00000000-0000-0000-0000-000000000001',business_name:'Test shop'};
const license={id:'bc52d5c4-2f26-4e11-bca9-626ccb4225d5',customer_id:customer.id,business_name:'Test shop',plan_id:'non_bir',status:'unactivated',active_devices:0,max_devices:2,issued_at:'2026-10-03T07:00:00Z'};
const key='AAAAA-BBBBB-CCCCC-DDDDD';
const reply=(value:unknown,status=200,type='application/json')=>({
  ok:status>=200&&status<300,status,headers:{get:(name:string)=>name==='content-type'?type:null},
  text:async()=>type==='application/json'?JSON.stringify(value):String(value),
});
function mock(options:{licenses?:boolean;activityFailure?:boolean;licenseFailure?:boolean;customerFailure?:boolean;customerSaveFailure?:boolean;html?:boolean;rotateFailure?:boolean;delayed?:boolean;activityRows?:unknown[];deviceRows?:unknown[]}={}){
  let issued=false;
  let created:typeof customer|null=null;
  let release:(()=>void)|undefined;
  const calls:string[]=[];
  const fetcher=vi.fn(async(input:string,init?:RequestInit)=>{
    const path=new URL(input).pathname, method=init?.method??'GET';
    calls.push(`${method} ${path}`);
    if(path==='/admin/me')return reply({user:'admin'});
    if(options.activityFailure&&path==='/admin/activity')return reply('<!DOCTYPE html>',404,'text/html');
    if(options.licenseFailure&&path==='/admin/licenses'&&method==='GET')return options.html?reply('<!DOCTYPE html>',404,'text/html'):reply({error:'Unavailable'},503);
    if(options.customerFailure&&path==='/admin/customers'&&method==='GET')return reply({error:'Unavailable'},503);
    if(options.customerSaveFailure&&path==='/admin/customers'&&method==='POST')return reply({error:'Invalid customer'},400);
    if(options.rotateFailure&&path.endsWith('/activation-key/rotate'))return reply({error:'Unavailable'},503);
    if(method==='POST'&&path==='/admin/licenses'){
      if(options.delayed)await new Promise<void>(resolve=>{release=resolve;});
      issued=true;return reply({id:license.id,activationKey:key});
    }
    if(method==='POST'&&path.endsWith('/activation-key/rotate'))return reply({id:license.id,activationKey:key});
    if(method==='POST'&&path==='/admin/customers'){
      const body=JSON.parse(String(init?.body));
      created={id:'00000000-0000-0000-0000-000000000002',business_name:body.businessName};
      return reply(created,201);
    }
    if(method==='POST')return reply({ok:true});
    const rows:Record<string,unknown>={
      '/admin/customers':[customer,...created?[created]:[]],
      '/admin/licenses':options.licenses||issued?[license]:[],
      '/admin/activity':options.activityRows??[],'/admin/devices':options.deviceRows??[],
      '/admin/plans':[{id:'non_bir',display_name:'Non-BIR'},{id:'bir_ready',display_name:'BIR-ready'}],
      [`/admin/licenses/${license.id}/devices`]:[],
    };
    return reply(rows[path]??[]);
  });
  vi.stubGlobal('fetch',fetcher);
  return {calls,fetcher,release:()=>release?.()};
}
afterEach(()=>{cleanup();vi.unstubAllGlobals();vi.restoreAllMocks();});
const ready=async()=>{await screen.findByRole('heading',{name:'Licenses'});await waitFor(()=>expect(screen.queryByText('Loading licenses...')).toBeNull());};
const issueDialog=()=>{fireEvent.click(screen.getAllByRole('button',{name:/Issue license/})[0]);return screen.getByRole('dialog');};
const more=()=>fireEvent.click(screen.getByLabelText('More actions for Test shop'));

test('existing licenses and customers load, navigation and independent empty states',async()=>{
  mock({licenses:true});render(<App/>);await ready();
  expect(screen.getByText('0 / 2')).toBeTruthy();
  fireEvent.click(screen.getByRole('button',{name:'Customers'}));
  expect(screen.getByText(/1 licenses/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button',{name:'Devices'}));
  await screen.findByText('No activated devices yet');
  fireEvent.click(screen.getByRole('button',{name:'Activity'}));
  await screen.findByText('No activity yet');
});
test('settings validates account and password forms before requests',async()=>{
  const x=mock();render(<App/>);await ready();
  fireEvent.click(screen.getByRole('button',{name:'Settings'}));
  expect(screen.getByRole('heading',{name:'Account & Security'})).toBeTruthy();
  fireEvent.click(screen.getByRole('button',{name:'Save changes'}));
  await screen.findByText(/Enter a display name and a username/);
  expect(x.calls).not.toContain('PATCH /admin/account');
  fireEvent.click(screen.getByRole('button',{name:'Change password'}));
  await screen.findByText(/Check the password fields/);
  expect(x.calls).not.toContain('POST /admin/account/password');
});
test('activity HTML 404 leaves licenses and customers usable',async()=>{
  mock({licenses:true,activityFailure:true});render(<App/>);await ready();
  expect(screen.getByText('0 / 2')).toBeTruthy();
  fireEvent.click(screen.getByRole('button',{name:'Customers'}));
  expect(screen.getByText(/1 licenses/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button',{name:'Activity'}));
  expect(await screen.findByText(/Activity endpoint was not found/)).toBeTruthy();
  expect(screen.queryByText(/Unexpected token/)).toBeNull();
});
test('failed license load shows error and Retry, not empty; customer failure stays separate',async()=>{
  const x=mock({licenseFailure:true,customerFailure:true,html:true});render(<App/>);await ready();
  expect(screen.getByText(/Licenses could not be loaded/)).toBeTruthy();
  expect(screen.getByRole('button',{name:'Retry'})).toBeTruthy();
  expect(screen.queryByText('No licenses yet')).toBeNull();
  fireEvent.click(screen.getByRole('button',{name:'Retry'}));
  await waitFor(()=>expect(x.calls.filter(c=>c==='GET /admin/licenses').length).toBe(2));
  fireEvent.click(screen.getByRole('button',{name:'Customers'}));
  expect(screen.getByText(/Customers could not be loaded/)).toBeTruthy();
});
test('issue existing customer, key display, copy, and immediate license refresh',async()=>{
  const x=mock();const clipboard={writeText:vi.fn(async()=>{})};Object.defineProperty(navigator,'clipboard',{configurable:true,value:clipboard});
  render(<App/>);await ready();const dialog=issueDialog();
  fireEvent.change(within(dialog).getByLabelText('Search existing customers'),{target:{value:'Test'}});
  expect(within(dialog).getByRole('option',{name:'Test shop'})).toBeTruthy();
  fireEvent.change(within(dialog).getByLabelText('Customer'),{target:{value:customer.id}});
  fireEvent.click(within(dialog).getByRole('button',{name:'Issue license'}));
  await screen.findByText(key);
  expect(screen.getByRole('heading',{name:'License issued successfully'})).toBeTruthy();
  expect(screen.queryByText(license.id)).toBeNull();
  fireEvent.click(screen.getByRole('button',{name:'Copy activation key'}));
  await waitFor(()=>expect(clipboard.writeText).toHaveBeenCalledWith(key));
  fireEvent.click(screen.getByRole('button',{name:'Done'}));
  await screen.findByText('0 / 2');
  expect(x.calls).toContain('POST /admin/licenses');
});
test('quick add selects saved customer and retains license fields; detects duplicate',async()=>{
  const x=mock();render(<App/>);await ready();const dialog=issueDialog();
  fireEvent.change(within(dialog).getByLabelText('Device limit'),{target:{value:'4'}});
  fireEvent.change(within(dialog).getByLabelText('Allowed reactivations'),{target:{value:'5'}});
  fireEvent.click(within(dialog).getByRole('button',{name:'+ Quick add customer'}));
  fireEvent.change(within(dialog).getByLabelText('Quick customer name'),{target:{value:' test  shop '}});
  expect(within(dialog).getByText(/A customer with this name already exists/)).toBeTruthy();
  fireEvent.click(within(dialog).getByRole('button',{name:'Use existing customer'}));
  expect((within(dialog).getByLabelText('Customer') as HTMLSelectElement).value).toBe(customer.id);
  fireEvent.click(within(dialog).getByRole('button',{name:'+ Quick add customer'}));
  fireEvent.change(within(dialog).getByLabelText('Quick customer name'),{target:{value:'New shop'}});
  fireEvent.change(within(dialog).getByLabelText('Quick customer phone'),{target:{value:'12345'}});
  fireEvent.change(within(dialog).getByLabelText('Quick customer notes'),{target:{value:'Call ahead'}});
  fireEvent.click(within(dialog).getByRole('button',{name:'Add customer'}));
  await waitFor(()=>expect((within(dialog).getByLabelText('Customer') as HTMLSelectElement).value).toBe('00000000-0000-0000-0000-000000000002'));
  expect((within(dialog).getByLabelText('Device limit') as HTMLInputElement).value).toBe('4');
  expect((within(dialog).getByLabelText('Allowed reactivations') as HTMLInputElement).value).toBe('5');
  expect(x.calls).toContain('POST /admin/customers');
  expect(x.calls.filter(c=>c==='POST /admin/customers')).toHaveLength(1);
  const save=x.fetcher.mock.calls.find(([,init])=>init?.method==='POST');
  expect(JSON.parse(String(save?.[1]?.body)).notes).toBe('Call ahead');
});
test('customer create appears immediately, failed save remains in dialog',async()=>{
  mock();render(<App/>);await ready();fireEvent.click(screen.getByRole('button',{name:'Customers'}));
  fireEvent.click(screen.getByRole('button',{name:'+ Create customer'}));
  fireEvent.change(screen.getByLabelText('Customer name'),{target:{value:'New shop'}});
  fireEvent.click(screen.getByRole('button',{name:'Create customer'}));
  await screen.findByText('New shop');
  cleanup();
  mock({customerSaveFailure:true});render(<App/>);await ready();fireEvent.click(screen.getByRole('button',{name:'Customers'}));
  fireEvent.click(screen.getByRole('button',{name:'+ Create customer'}));
  fireEvent.change(screen.getByLabelText('Customer name'),{target:{value:'New shop'}});
  fireEvent.click(screen.getByRole('button',{name:'Create customer'}));
  await screen.findByText(/Could not create customer/);
  expect(screen.queryByText('Customer created successfully.')).toBeNull();
});
test('issue and rotate block duplicate clicks and show errors',async()=>{
  const x=mock({delayed:true});render(<App/>);await ready();const dialog=issueDialog();
  fireEvent.change(within(dialog).getByLabelText('Customer'),{target:{value:customer.id}});
  fireEvent.click(within(dialog).getByRole('button',{name:'Issue license'}));
  await screen.findByRole('button',{name:'Issuing...'});
  fireEvent.click(screen.getByRole('button',{name:'Issuing...'}));
  expect(x.calls.filter(c=>c==='POST /admin/licenses')).toHaveLength(1);
  x.release();await screen.findByText(key);cleanup();
  mock({licenses:true,rotateFailure:true});render(<App/>);await ready();more();fireEvent.click(screen.getByRole('button',{name:'Rotate activation key'}));fireEvent.click(screen.getByRole('button',{name:'Rotate key'}));
  await screen.findByText(/Could not rotate activation key/);
  expect(screen.getByRole('dialog')).toBeTruthy();
});
test('rotate success, activity event, and aggregate devices route',async()=>{
  const x=mock({licenses:true,activityRows:[{id:'event-1',license_id:license.id,event_type:'license.activation_key_rotate',created_at:'2026-10-03T07:00:00Z'}],deviceRows:[{id:'device-1',license_id:license.id,business_name:'Test shop',device_fingerprint:'fingerprint-123456789',status:'active',activated_at:'2026-10-03T07:00:00Z'}]});
  render(<App/>);await ready();more();fireEvent.click(screen.getByRole('button',{name:'Rotate activation key'}));
  expect(x.calls).not.toContain(`POST /admin/licenses/${license.id}/activation-key/rotate`);
  fireEvent.click(screen.getByRole('button',{name:'Rotate key'}));
  await screen.findByText(key);
  fireEvent.click(screen.getByRole('button',{name:'Done'}));
  fireEvent.click(screen.getByRole('button',{name:'Devices'}));
  await screen.findByText('fingerprint-1234…');
  expect(x.calls).toContain('GET /admin/devices');
  fireEvent.click(screen.getByRole('button',{name:'Activity'}));
  expect(screen.getAllByText('Activation key rotated').length).toBeGreaterThan(0);
});
