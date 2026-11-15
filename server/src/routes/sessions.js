const express = require('express');
const Session = require('../models/Session');
const auth = require('../middleware/auth');
const router = express.Router();

// 获取用户的所有练习会话
router.get('/', auth, async (req, res) => {
  try {
    const sessions = await Session.find({ userId: req.user._id })
      .sort({ startTime: -1 });
    res.json(sessions);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
});

// 获取指定日期的练习会话
router.get('/date/:date', auth, async (req, res) => {
  try {
    const date = new Date(req.params.date);
    const startOfDay = new Date(date.setHours(0, 0, 0, 0));
    const endOfDay = new Date(date.setHours(23, 59, 59, 999));

    const sessions = await Session.find({
      userId: req.user._id,
      startTime: { $gte: startOfDay, $lte: endOfDay }
    }).sort({ startTime: -1 });

    res.json(sessions);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
});

// 创建新的练习会话
router.post('/', auth, async (req, res) => {
  try {
    const session = new Session({
      ...req.body,
      userId: req.user._id
    });
    await session.save();
    res.status(201).json(session);
  } catch (error) {
    res.status(400).json({ message: error.message });
  }
});

// 更新练习会话
router.patch('/:id', auth, async (req, res) => {
  try {
    const session = await Session.findOne({
      _id: req.params.id,
      userId: req.user._id
    });

    if (!session) {
      return res.status(404).json({ message: '未找到该练习会话' });
    }

    Object.assign(session, req.body);
    await session.save();
    res.json(session);
  } catch (error) {
    res.status(400).json({ message: error.message });
  }
});

// 删除练习会话
router.delete('/:id', auth, async (req, res) => {
  try {
    const session = await Session.findOneAndDelete({
      _id: req.params.id,
      userId: req.user._id
    });

    if (!session) {
      return res.status(404).json({ message: '未找到该练习会话' });
    }

    res.json({ message: '练习会话已删除' });
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
});

module.exports = router; 