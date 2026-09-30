import React from 'react';
import {afterEach, expect, test, vi} from 'vitest';
import {cleanup, fireEvent, render, screen, waitFor} from '@testing-library/react';
import {App} from './main';

afterEach(()=>{cleanup();vi.unstubAllGlobals();});

test('admin login gates licensing controls and loads customer/license views', async()=>{
  const calls:string[]=[];
  vi.stubGlobal('fetch',vi.fn(async(input:string,init?:RequestInit)=>{
    const path=new URL(input).pathname; calls.push(path);
    if(path==='/admin/me') return {ok:false,status:401,json:async()=>({error:'Admin login required'})};
    if(path==='/admin/login') {
      const body=JSON.parse(String(init?.body));
      return {ok:body.username==='admin'&&body.password==='correct',status:body.password==='correct'?200:401,
        json:async()=>body.password==='correct'?{user:'admin'}:{error:'Invalid credentials'}};
    }
    const rows:Record<string,unknown>={
      '/admin/customers':[{id:'customer-1',business_name:'Test shop'}],
      '/admin/licenses':[], '/admin/activation-events':[],
      '/admin/plans':[{id:'non_bir',display_name:'Non-BIR'}]
    };
    return {ok:true,status:200,json:async()=>rows[path]??[]};
  }));
  render(<App/>);
  expect(screen.queryByText('Issue license')).toBeNull();
  fireEvent.change(screen.getByLabelText('Username'),{target:{value:'admin'}});
  fireEvent.change(screen.getByLabelText('Password'),{target:{value:'correct'}});
  fireEvent.click(screen.getByText('Log in'));
  await waitFor(()=>expect(screen.getByText('Issue license')).toBeTruthy());
  expect(screen.getAllByText(/Test shop/).length).toBeGreaterThan(0);
  expect(calls).toContain('/admin/customers');
});
