USE [qptreasuredb]
GO
/****** Object:  StoredProcedure [dbo].[GSP_GP_UserSignIn]    Script Date: 05/24/2016 09:56:08 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO








----------------------------------------------------------------------------------------------------

-- 用户签到
ALTER PROC [dbo].[GSP_GP_UserSignIn]
	@dwUserID INT,
	@cbIsVIP INT,
	@strErrorDescribe NVARCHAR(127) OUTPUT		-- 输出信息
AS

-- 属性设置
SET NOCOUNT ON

--变量声明
DECLARE @LastSignDayNum INT		-- 最近一次签到时间
DECLARE @RealRewardCount INT	-- 实际奖励数量, 用于从RewardConfig里面获取对应的奖励信息
DECLARE @RealRewardType INT		-- 实际奖励类型, 用于从RewardConfig里面获取对应的奖励信息
DECLARE @RealRewardSignDay INT  -- 实际签到天数, 用于从RewardConfig里面获取对应的奖励信息
DECLARE @LastSignDay DateTime
DECLARE @MaxDay INT  -- 签到最大天数

-- Reward type and count
DECLARE @RewardType INT
DECLARE @RewardCount INT

DECLARE @ScoreRes BIGINT	-- 最后加完签到奖励之后的金币结果
DECLARE @LotteryRes BIGINT	-- 奖券的最后结果
SET @ScoreRes = 0
SET @LotteryRes = 0

-- 执行逻辑
BEGIN
	-- VIP 账户才能领取VIP签到奖励
	IF @cbIsVIP = 1
	BEGIN
        IF (NOT EXISTS (SELECT UserID FROM QPAccountsDB.dbo.VipInfo WHERE UserID=@dwUserID))
            BEGIN
                SET @strErrorDescribe = '对不起, 只有VIP用户才能领取' 
                RETURN 25
            END
	END

	-- 获取一轮签满的天数, 这里有一个默认就是VIP 和 普通用户的签满天数是相同的, 一般设置为 7 的倍数
	SELECT @MaxDay = COUNT(*) FROM qptreasuredb.dbo.SignRewardConfig WHERE IsVIP = 0
	

    -- 如果用户之前没有签到过, 那么插入一条用户签到记录
    IF (NOT EXISTS (SELECT UserID FROM SignLog WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP))
        BEGIN
			-- 从Config表里面拿到第一天的信息
			SELECT @RewardCount=RewardCount, @RewardType=RewardType FROM SignRewardConfig WHERE DayNum = 1 AND IsVIP = @cbIsVIP
			
			-- 插入第一天的信息
            INSERT INTO SignLog (UserID, LastSignDay, LastSignDayNum, RewardType, RewardCount ,IsVIP) 
				VALUES (@dwUserID, GETDATE(), 1, @RewardType, @RewardCount, @cbIsVIP)
            SET @RealRewardSignDay = 1
        END
    ELSE 
    BEGIN
		-- 如果用户之前签到过, 获取对应的信息用于计算
		Select @LastSignDay = LastSignDay, @LastSignDayNum = LastSignDayNum FROM SignLog WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
		
		-- 按照当前的签到设计, 签到情况有:
		-- 1. 今日已签到, 
		-- 2. 昨天签到, 今天连签 
		-- 3. 上次签到的日期, 比昨天更早, 签到从第一天开始
		
		-- 1. 今日已签到
        IF(DATEDIFF(DAY, @LastSignDay, GETDATE()) = 0) 
            BEGIN
                SET @strErrorDescribe = '今天已经签到过了, 请不要重复签到' 
                RETURN 25
            END
        -- 2. 连签
        ELSE IF (DATEDIFF(DAY, @LastSignDay, GETDATE()) = 1) -- 昨天已经签到, 今天正常签到 
            BEGIN
                SET @RealRewardSignDay = @LastSignDayNum + 1
                IF @RealRewardSignDay > @MaxDay
                BEGIN 
					SET @RealRewardSignDay = 1
                END
                DECLARE @IsExtraBonusOver INT
				SET @IsExtraBonusOver = 0	
                IF (@RealRewardSignDay = 7)
                BEGIN
					SET @IsExtraBonusOver = 1	
                END
                UPDATE SignLog SET LastSignDay = GETDATE(), LastSignDayNum = @RealRewardSignDay, IsExtraBonusOver = @IsExtraBonusOver WHERE  UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
        -- 3. 签到记录刷新
        ELSE IF (DATEDIFF(DAY, @LastSignDay, GETDATE()) > 1) -- 之前的签到作废, 从第一天开始签到
            BEGIN
                SET @RealRewardSignDay = 1
                UPDATE SignLog SET LastSignDay = GETDATE(), LastSignDayNum = @RealRewardSignDay, IsSignInInterrupt = 1 WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
        
        -- 4. 其他情况
        ELSE 
            BEGIN
                SET @strErrorDescribe = '签到日期错误' 
                RETURN 25
            END
    END

	DECLARE @MaxSigndayNum INT
	set @MaxSigndayNum = 0
	DECLARE @FirstSignAllDayRoundNum INT 
	SET @FirstSignAllDayRoundNum = 0
	select @MaxSigndayNum = MaxSigndayNum, @FirstSignAllDayRoundNum = FirstSignAllDayRoundNum FROM qptreasuredb.dbo.SignLog WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
	IF (@RealRewardSignDay = 1)  -- 签到的轮数, 这个数字根据第一天的签到次数来计算.
	begin
		update qptreasuredb.dbo.SignLog SET SignRoundCount = SignRoundCount + 1 WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
	END 
	IF (@RealRewardSignDay = 7)  -- 签满的轮数, 根据第七天的签到次数来计算
	begin 
		update qptreasuredb.dbo.SignLog SET SignAllDayCount = SignAllDayCount + 1 WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
		IF (@FirstSignAllDayRoundNum = 0)
		begin 
			UPDATE qptreasuredb.dbo.SignLog set FirstSignAllDayRoundNum = SignRoundCount WHERE UserID = @dwUserID  AND IsVIP = @cbIsVIP
		END 
	end
	IF ((@RealRewardSignDay >= 1) AND (@RealRewardSignDay <= 7)) AND (@RealRewardSignDay > @MaxSigndayNum)
	begin
		UPDATE qptreasuredb.dbo.SignLog SET MaxSigndayNum = @RealRewardSignDay WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
	end

	-- 下面是数据的更新
    IF EXISTS (SELECT RewardCount, RewardType FROM SignRewardConfig WHERE DayNum = @RealRewardSignDay AND IsVIP = @cbIsVIP)
    BEGIN
		DECLARE @ExtraBonusSignedDay INT
		SET @ExtraBonusSignedDay = 0
	    SELECT @RealRewardCount = RewardCount, @RealRewardType = RewardType FROM SignRewardConfig 
            WHERE DayNum = @RealRewardSignDay AND IsVIP = @cbIsVIP
           
        SELECT @ExtraBonusSignedDay = ExtraBonusSignedDay FROM qptreasuredb.dbo.SignLog WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP

        -- 更新RewardCount and RealRewardType ExtraBonusSignedDay
        IF (@cbIsVIP = 0)
        BEGIN
			DECLARE @tmpBonusDay INT
            IF (@RealRewardSignDay = 2) AND (@ExtraBonusSignedDay & Power(2, (2 - 1)) = 0) -- normal day2 五元话费
            BEGIN
				SET @tmpBonusDay = 2 
                SET @RealRewardType = 3
                SET @RealRewardCount = 5
                UPDATE qptreasuredb.dbo.SignLog SET ExtraBonusSignedDay = ExtraBonusSignedDay | Power(2, (@tmpBonusDay - 1)) WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
            
            IF (@RealRewardSignDay = 4) AND (@ExtraBonusSignedDay & Power(2, (4 - 1)) = 0) -- normal day2 五元话费
            BEGIN
				SET @tmpBonusDay = 4 
                SET @RealRewardType = 10
                SET @RealRewardCount = 10
                UPDATE qptreasuredb.dbo.SignLog SET ExtraBonusSignedDay = ExtraBonusSignedDay | Power(2, (@tmpBonusDay - 1)) WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
            
            IF (@RealRewardSignDay = 7) AND (@ExtraBonusSignedDay & Power(2, (7 - 1)) = 0) -- normal day7 生化炮
            BEGIN
				SET @tmpBonusDay = 7 
                SET @RealRewardType = 12
                SET @RealRewardCount = 1
                UPDATE qptreasuredb.dbo.SignLog SET ExtraBonusSignedDay = ExtraBonusSignedDay | Power(2, (@tmpBonusDay - 1)) WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
        END
        ELSE
        BEGIN
			SET @tmpBonusDay = 0
            IF (@RealRewardSignDay = 1) AND (@ExtraBonusSignedDay & Power(2, (1 - 1)) = 0)   -- vip day 1  奖券 1000
            BEGIN
				SET @tmpBonusDay = 1
                SET @RealRewardType = 2
                SET @RealRewardCount = 1000
                UPDATE qptreasuredb.dbo.SignLog SET ExtraBonusSignedDay = ExtraBonusSignedDay | Power(2, (@tmpBonusDay - 1)) WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
            IF (@RealRewardSignDay = 3) AND (@ExtraBonusSignedDay & Power(2, (3 - 1)) = 0)   -- vip day 1  奖券 1000
            BEGIN
				SET @tmpBonusDay = 3
                SET @RealRewardType = 10
                SET @RealRewardCount = 20
                UPDATE qptreasuredb.dbo.SignLog SET ExtraBonusSignedDay = ExtraBonusSignedDay | Power(2, (@tmpBonusDay - 1)) WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
            IF (@RealRewardSignDay = 6) AND (@ExtraBonusSignedDay & Power(2, (6 - 1)) = 0)   -- vip day 6  初级珍珠 1
            BEGIN
				SET @tmpBonusDay = 6
                SET @RealRewardType = 4
                SET @RealRewardCount = 1
                UPDATE qptreasuredb.dbo.SignLog SET ExtraBonusSignedDay = ExtraBonusSignedDay | Power(2, (@tmpBonusDay - 1)) WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
            IF (@RealRewardSignDay = 7) AND (@ExtraBonusSignedDay & Power(2, (7 - 1)) = 0)   -- vip day 7  10元话费
            BEGIN
				SET @tmpBonusDay = 7
                SET @RealRewardType = 3
                SET @RealRewardCount = 10   
                UPDATE qptreasuredb.dbo.SignLog SET ExtraBonusSignedDay = ExtraBonusSignedDay | Power(2, (@tmpBonusDay - 1)) WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
            END
        END
        
        -- UPDATE the last reward type AND reward count
        --update qptreasuredb.dbo.SignLog SET RewardCount = @RealRewardCount, RewardType = @RewardType WHERE UserID = @dwUserID AND IsVIP = @cbIsVIP
        

		DECLARE @strDescriptionTmp NVARCHAR(100)
		DECLARE @ResCount BIGINT
		DECLARE @IsCannon INT	
		SET @IsCannon = 0

	    IF @RealRewardType = 1  -- 金币
	        BEGIN
	            UPDATE GameScoreInfo SET Score = Score + @RealRewardCount WHERE UserID = @dwUserID
	            set @strDescriptionTmp = '金币'
	            exec qprecorddb.dbo.NET_PW_AddGoldLog @dwUserID,@RealRewardCount,3,0,1
	        END
	    ELSE IF @RealRewardType = 2  -- 奖券 注意不要和奖项的type弄混
	        BEGIN
				IF EXISTS (select Userid from qptreasuredb.dbo.UserItem where userid = @dwUserID and [Type]=105)
					BEGIN
			           UPDATE UserItem SET [Count] = [Count] + @RealRewardCount WHERE UserID = @dwUserID AND [Type]=105
			        END
		        ELSE
					BEGIN 
					   	INSERT UserItem ([type], [count], [maxcount], [userid], [guidtag1], [guidtag2], [guidtag3], [guidtag4], source, subsource, isgamepreload, flag)
						VALUES (105, @RealRewardCount, @RealRewardCount, @dwUserID, 0, 0, 0, 0, 0, 0, 1, 11)
			        END
	           select @LotteryRes = [Count] from UserItem where userid = @dwUserID And [Type] = 105
	           SET @strDescriptionTmp = '奖券'
	           
	           -- 奖券奖励
	           INSERT qptreasuredb.dbo.RecordLottery(UserID,Lottery,KindID,ServerID,Flag,AddTime)
VALUES (@dwUserID,@RealRewardCount,0,0,2,GETDATE())
	        END
		ELSE IF @RealRewardType = 3 -- 话费
	        BEGIN
				IF EXISTS (select Userid from qptreasuredb.dbo.UserItem where userid = @dwUserID and [Type]=113)
					BEGIN
			           UPDATE UserItem SET [Count] = [Count] + @RealRewardCount WHERE UserID = @dwUserID AND [Type]=113
			           -- 话费记录
			           INSERT qptreasuredb.dbo.RecordMobileMoney(UserID,MobileMoney,AddTime,KindID,ServerID) VALUES(@dwUserID,@RealRewardCount,GETDATE(),0,0)
			        END
		        ELSE
					BEGIN 
					   	INSERT UserItem ([type], [count], [maxcount], [userid], [guidtag1], [guidtag2], [guidtag3], [guidtag4], source, subsource, isgamepreload, flag)
						VALUES (113, @RealRewardCount, @RealRewardCount, @dwUserID, 0, 0, 0, 0, 0, 0, 1, 11)
			        END
			        
			   select @LotteryRes = [Count] from UserItem where userid = @dwUserID And [Type] = 105
	           SET @strDescriptionTmp = '元话费'
	        END

	    ELSE IF @RealRewardType = 4  -- 初级珍珠
	        BEGIN
	           UPDATE QPAccountsDB.dbo.Backpack SET item0 = item0 + @RealRewardCount WHERE UserID = @dwUserID 
               SET @strDescriptionTmp = '颗初级珍珠'
	        END
	    ELSE IF @RealRewardType = 5  -- 中级珍珠
	        BEGIN
	           UPDATE QPAccountsDB.dbo.Backpack SET item1 = item1 + @RealRewardCount WHERE UserID = @dwUserID 
               SET @strDescriptionTmp = '颗中级珍珠'
	        END
	    ELSE IF @RealRewardType = 6  -- 高级珍珠
	        BEGIN
	           UPDATE QPAccountsDB.dbo.Backpack SET item2 = item2 + @RealRewardCount WHERE UserID = @dwUserID 
               SET @strDescriptionTmp = '颗高级珍珠'
	        END
	    ELSE IF @RealRewardType = 7  -- 加速
	        BEGIN
	           UPDATE QPAccountsDB.dbo.Backpack SET item5 = item5 + @RealRewardCount WHERE UserID = @dwUserID 
               SET @strDescriptionTmp = '次加速'
	        END
	    ELSE IF @RealRewardType = 8  -- 散射
	        BEGIN
	           UPDATE QPAccountsDB.dbo.Backpack SET item6 = item6 + @RealRewardCount WHERE UserID = @dwUserID 
               SET @strDescriptionTmp = '次散射'
	        END
	    ELSE IF @RealRewardType = 9  -- 暴击
	        BEGIN
	           UPDATE QPAccountsDB.dbo.Backpack SET item7 = item7 + @RealRewardCount WHERE UserID = @dwUserID 
               SET @strDescriptionTmp = '次暴击'
	        END
	    ELSE IF @RealRewardType = 10  -- 小丑免费抽奖次数
	        BEGIN
	           UPDATE QPAccountsDB.dbo.Backpack SET item8 = item8 + @RealRewardCount WHERE UserID = @dwUserID 
               SET @strDescriptionTmp = '张藏宝图'
	        END
        ELSE IF @RealRewardType >= 11 AND @RealRewardType <= 19
            BEGIN
                DECLARE @CannonNUM INT
                SET @CannonNUM = 2 + (@RealRewardType - 11)
	            UPDATE QPAccountsDB.dbo.Backpack SET item4 = item4 | POWER(2, @CannonNUM) WHERE UserID = @dwUserID 
                IF @RealRewardType = 11
                    BEGIN
                        SET @strDescriptionTmp = '疾风炮'
                    END
                ELSE IF @RealRewardType = 12
                    BEGIN
                        SET @strDescriptionTmp = '生化炮'
                    END
                ELSE IF @RealRewardType = 13
                    BEGIN
                        SET @strDescriptionTmp = '闪电炮'
                    END
                ELSE IF @RealRewardType = 14
                    BEGIN
                        SET @strDescriptionTmp = '激光炮'
                    END
                ELSE IF @RealRewardType = 15
                    BEGIN
                        SET @strDescriptionTmp = '冲锋炮'
                    END
                ELSE IF @RealRewardType = 16
                    BEGIN
                        SET @strDescriptionTmp = '月牙炮'
                    END
                ELSE IF @RealRewardType = 17
                    BEGIN
                        SET @strDescriptionTmp = '火球炮'
                    END
                ELSE IF @RealRewardType = 18
                    BEGIN
                        SET @strDescriptionTmp = '寒冰炮'
                    END
                ELSE IF @RealRewardType = 19
                    BEGIN
                        SET @strDescriptionTmp = '冰霜炮'
                    END
                SET @IsCannon = 1
            END

    ELSE
        BEGIN
            SET @strErrorDescribe = '奖励类型获取失败' 
           RETURN 25
        END
    
	IF (@IsCannon = 1) 
	BEGIN 
	    SET @strErrorDescribe = '签到成功获得' +  @strDescriptionTmp 
	END 	
	else 
	BEGIN 
	    SET @strErrorDescribe = '签到成功获得' + CONVERT(VARCHAR(5), @RealRewardCount) + @strDescriptionTmp 
	END 
    END
    ELSE
	    BEGIN
		    SET @strErrorDescribe = '签到信息错误无法找到对应的奖励信息' 
	    END 
END

select @ScoreRes = Score from GameScoreInfo where UserID = @dwUserID
select @LotteryRes = [Count] from UserItem where userid = @dwUserID And [Type] = 105
SELECT @ScoreRes AS ScoreCount, @LotteryRes AS LotteryCount, @cbIsVIP AS IsVIP 

RETURN 24






