const { chromium } = require('/Users/ocean/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const path = require('path');
const fs = require('fs');
const root = path.resolve(__dirname, '..');
(async () => {
 const browser = await chromium.launch({headless:true,channel:'chrome'});
 const page = await browser.newPage({viewport:{width:1440,height:980},deviceScaleFactor:1});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('file://' + path.join(root,'docs/design/prototype.html'));
 for(const name of ['overview','employees','tasks','tools','assets']){
  await page.locator(`[data-page="${name}"]`).click();
  await page.screenshot({path:path.join(root,`docs/design/${name}.png`),fullPage:true});
 }
 await page.locator('[data-page="tasks"]').click();
 await page.getByRole('button',{name:'验收通过',exact:true}).click();
 if(!await page.locator('.detail .badge').filter({hasText:'已完成'}).count())throw Error('review transition failed');
 await page.locator('#new-task').click();
 await page.locator('#name').fill('测试设计任务');await page.locator('#input').fill('验证新建任务');
 await page.getByRole('button',{name:'保存演示记录'}).click();
 if(!await page.locator('tbody').getByText('测试设计任务',{exact:true}).count())throw Error('task creation failed');
 await page.locator('[data-page="tools"]').click();await page.getByRole('button',{name:'添加CLI工具'}).click();
 await page.locator('#name').fill('样例工具');await page.locator('#path').fill('/usr/bin/printf');
 await page.getByRole('button',{name:'保存演示记录'}).click();
 if(!await page.locator('tbody').getByText('样例工具',{exact:true}).count())throw Error('tool creation failed');
 await page.locator('[data-page="employees"]').click();await page.getByRole('button',{name:'新增员工'}).click();
 await page.locator('#name').fill('样例员工');await page.locator('#role').fill('测试职责');
 await page.getByRole('button',{name:'保存演示记录'}).click();
 if(!await page.locator('.cards').getByText('样例员工',{exact:true}).count())throw Error('employee creation failed');
 await page.locator('#page-search').fill('样例员工');if(await page.locator('.employee').count()!==1)throw Error('search failed');
 await page.setViewportSize({width:1100,height:800});
 for(const name of ['overview','employees','tasks','tools','assets']){
  await page.locator(`[data-page="${name}"]`).click();
  if(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth))throw Error('horizontal overflow: '+name);
 }
 if(errors.length)throw Error(errors.join('\n'));
 fs.mkdirSync(path.join(root,'work'),{recursive:true});
 fs.writeFileSync(path.join(root,'work/design-check.json'),JSON.stringify({pages:5,viewports:[1440,1100],checks:['navigation','task creation','review','tool creation','employee creation','search','no overflow','no runtime errors'],passed:true},null,2));
 console.log('Design checks passed; 5 screenshots saved');await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
