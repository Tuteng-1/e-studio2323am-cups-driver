-- eSTUDIO 打印机管理
--
-- 本脚本只是界面外壳：收集用户输入 -> 拼出 estudioctl.sh 子命令 -> 展示结果。
-- 所有业务逻辑都在 estudioctl.sh（随 app 一起打包在 Contents/Resources）。

property ctlFile : "estudioctl.sh"

-- 执行 ctl；admin 为真时弹系统密码框。失败时把错误信息交给调用方
on ctlRaw(args, admin)
	set ctlPath to POSIX path of (path to resource ctlFile)
	set cmdStr to quoted form of ctlPath & " " & args
	if admin then
		return do shell script cmdStr with administrator privileges
	else
		return do shell script cmdStr
	end if
end ctlRaw

-- 出错时弹提示框并返回 ""（空串表示失败）
on ctl(args, admin)
	try
		return ctlRaw(args, admin)
	on error msg
		display dialog "操作失败：" & return & return & msg buttons {"好"} default button "好" with icon stop
		return ""
	end try
end ctl

on askText(prompt, def)
	set r to display dialog prompt default answer def buttons {"取消", "继续"} default button "继续" with title "eSTUDIO 打印机管理"
	if button returned of r is "取消" then return missing value
	return text returned of r
end askText

-- 二选一确认框。第一个按钮是回车默认选中的那个：
-- 可选操作（打测试页）和破坏性操作（删除/卸载）都把「更安全」的选项放第一位。
-- 返回用户实际点的按钮名。
on choose(prompt, defaultLabel, otherLabel)
	set r to display dialog prompt buttons {defaultLabel, otherLabel} default button defaultLabel with title "eSTUDIO 打印机管理"
	return button returned of r
end choose

on say(msg)
	display dialog msg buttons {"好"} default button "好" with title "eSTUDIO 打印机管理"
end say

-- 解析 `list` 输出（NAME<TAB>URI）为记录列表
on queueList()
	set raw to ctl("list", false)
	if raw is "" then return {}
	set out to {}
	repeat with ln in paragraphs of raw
		set s to ln as text
		if s is not "" then
			set t to offset of tab in s
			if t > 0 then
				set qname to text 1 thru (t - 1) of s
				set end of out to {qname:qname, quri:(text (t + 1) thru -1 of s), qlabel:(qname & "  —  " & text (t + 1) thru -1 of s)}
			else
				set end of out to {qname:s, quri:"", qlabel:s}
			end if
		end if
	end repeat
	return out
end queueList

-- 让用户挑一个本驱动创建队列；返回队列名，取消则返回 missing value
on pickQueue(prompt)
	set qs to queueList()
	if (count of qs) is 0 then
		say("尚未添加本驱动的打印机，请先「添加打印机」。")
		return missing value
	end if
	set labels to {}
	repeat with q in qs
		set end of labels to (qlabel of q)
	end repeat
	set sel to choose from list labels with prompt prompt with title "eSTUDIO 打印机管理"
	if sel is false then return missing value
	set chosen to item 1 of sel
	repeat with q in qs
		if (qlabel of q) is chosen then return (qname of q)
	end repeat
	return missing value
end pickQueue

on addPrinter()
	set qname to askText("队列名（字母、数字、下划线、连字符；默认 eSTUDIO2823AM）：", "eSTUDIO2823AM")
	if qname is missing value then return
	if qname is "" then
		say("队列名不能为空。")
		return
	end if

	set addr to askText("打印机 IP 或主机名（可带端口，如 192.0.2.10 或 192.0.2.10:9100）：", "")
	if addr is missing value then return
	if addr is "" then
		say("IP / 主机名不能为空。")
		return
	end if

	set cmdStr to "add " & quoted form of qname & " " & quoted form of addr
	if choose("把 " & qname & " 设为默认打印机？", "设为默认", "不设为默认") is "设为默认" then set cmdStr to cmdStr & " --default"
	-- 打印测试页是可选的，默认不打
	if choose("添加后立即打印测试页？", "不打印", "打印测试页") is "打印测试页" then set cmdStr to cmdStr & " --test"

	set r to ctl(cmdStr, true)
	if r is not "" then say(r)
end addPrinter

on setPort()
	set qname to pickQueue("选择要修改端口的打印机：")
	if qname is missing value then return
	set addr to askText("新的 IP 或主机名（" & qname & "）：", "")
	if addr is missing value or addr is "" then return
	set r to ctl("set-port " & quoted form of qname & " " & quoted form of addr, true)
	if r is not "" then say(r)
end setPort

on testPage()
	set qname to pickQueue("选择要打印测试页的打印机：")
	if qname is missing value then return
	set r to ctl("testpage " & quoted form of qname, false)
	if r is not "" then say(r)
end testPage

on removePrinter()
	set qname to pickQueue("选择要删除的打印机：")
	if qname is missing value then return
	if choose("删除打印机「" & qname & "」？它的打印队列与配置文件都会一并删除。", "不删除", "删除") is not "删除" then return
	set r to ctl("remove " & quoted form of qname, true)
	if r is not "" then say(r)
end removePrinter

on uninstallDriver()
	if choose("卸载驱动？这会从系统移除 filter 与 PPD，卸载后本驱动创建的打印机将无法打印。", "不卸载", "卸载驱动") is not "卸载驱动" then return
	set cmdStr to "uninstall-driver"
	if choose("同时删除本驱动创建的所有打印机？", "保留打印机", "一并删除") is "一并删除" then set cmdStr to cmdStr & " --remove-queues"
	set r to ctl(cmdStr, true)
	if r is not "" then say(r)
end uninstallDriver

on showStatus()
	if ctl("status", false) is "installed" then
		set sText to "已安装"
	else
		set sText to "未安装"
	end if
	set qs to queueList()
	set body to "驱动：" & sText & return & "打印机：" & (count of qs) & " 台"
	if (count of qs) is 0 then
		set body to body & "（可用「添加打印机」添加）"
	else
		repeat with q in qs
			set body to body & return & "  •  " & (qlabel of q)
		end repeat
	end if
	say(body)
end showStatus

on run
	if ctl("status", false) is not "installed" then
		if choose("驱动尚未安装。现在安装？需要管理员密码。", "安装驱动", "退出") is not "安装驱动" then return
		set r to ctl("install-driver", true)
		if r is "" then return
		say(r)
	else
		say("eSTUDIO 打印机管理就绪。" & return & return & "请选择要执行的操作。")
	end if

	repeat
		set choice to choose from list {"添加打印机", "设置端口", "打印测试页", "删除打印机", "查看状态", "卸载驱动", "退出"} with prompt "eSTUDIO 打印机管理" with title "eSTUDIO 打印机管理"
		if choice is false then exit repeat
		set c to item 1 of choice
		if c is "添加打印机" then
			addPrinter()
		else if c is "设置端口" then
			setPort()
		else if c is "打印测试页" then
			testPage()
		else if c is "删除打印机" then
			removePrinter()
		else if c is "查看状态" then
			showStatus()
		else if c is "卸载驱动" then
			uninstallDriver()
		else
			exit repeat
		end if
	end repeat
end run
